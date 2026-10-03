# 自由创作台 Skill 对照表

测试脚本：`E:\huahuoai\tools\Invoke-DocumentChangeProposalSimulator.ps1`

## 当前可传的 Skill Profile

自由创作台的 Document Proposal 接口当前固定使用 Agent Profile：`self_media_creation`。

线上 Catalog 当前只发布了一个可选 Skill Profile：

| 功能入口 | 传入的 `skillProfileIds` |
| --- | --- |
| 自由创作台全部文稿编辑、改写、分析和创作任务 | `self_media_creation_advisor` |

因此，当前调用参数固定为：

```powershell
-SkillProfileIds @('self_media_creation_advisor')
```

## 功能与内部能力对照

下表中的“内部能力名”用于说明自由创作 Agent 会按什么能力处理需求。它们不是当前 API 可直接传入的 `skillProfileIds`；所有功能在请求里仍传 `self_media_creation_advisor`。

| 功能 | 内部能力名 | `skillProfileIds` 实际传值 |
| --- | --- | --- |
| 分析目标观众的需求、兴趣、迫切性与深层动机 | `demand-deepening`（需求深化） | `self_media_creation_advisor` |
| 基于已有选题探索更多方向、切入角度和差异化选题 | `differentiation-strengthening`（选题强化） | `self_media_creation_advisor` |
| 从已有材料提炼深层命题、机制与跨学科解释 | `cross-disciplinary-theory-elevation`（理论拔高） | `self_media_creation_advisor` |
| 重构内容的信息层次、信息密度、信息簇与中段推进 | `atomic-structure`（原子化信息结构） | `self_media_creation_advisor` |
| 扩写选中的句子或段落，增加例子、机制、边界或有效信息 | `atomic-incremental-expansion`（原子增量扩写） | `self_media_creation_advisor` |
| 将既有内容按固定二分之一规则压缩并降低理解成本 | `content-shortening-simplification`（缩写简化） | `self_media_creation_advisor` |
| 诊断或构建“你、我、他”的叙述关系与内容发动机 | `audience-relationship-shift`（你我他关系诊断与构建） | `self_media_creation_advisor` |
| 优化文案开头前三句话中的用户标签和进入场景 | `opening-labeling`（开头标签化） | `self_media_creation_advisor` |
| 优化文案开头前三句话中的新鲜理解和反常识表达 | `opening-defamiliarization`（开头陌生化） | `self_media_creation_advisor` |
| 从已有材料提炼准确、可记忆、可引用的一句话 | `memorable-line-distillation`（金句提炼） | `self_media_creation_advisor` |
| 依据需求、卖点和决策成本规划成交路径与话术 | `sales-messaging-planning`（成交七步策划） | `self_media_creation_advisor` |
| 检查文字在传播场景中的法律、平台和通用风控风险 | `text-compliance-risk-check`（文字违规风险检查） | `self_media_creation_advisor` |
| 将文字内容转为真实可交付的成品配图 | `scene-design`（影像增强成品配图） | `self_media_creation_advisor` |
| 为口播稿或口播锚点设计解释性辅助画面 | `spoken-explanatory-visuals`（口播解释性画面） | `self_media_creation_advisor` |

## 结论

自由创作台的请求结构支持 `skillProfileIds`，但当前线上只允许选择 `self_media_creation_advisor` 一个公开 Profile。

也就是说：现在可以根据不同需求使用不同功能，但不能把 `demand-deepening`、`scene-design`、`text-compliance-risk-check` 等内部能力名直接传入 `skillProfileIds`。传这些值会被候选 Skill 校验拒绝。要让前端能分别选择这些功能，需要把它们分别发布为独立的公开 Skill Profile，并加入 `self_media_creation` 的线上候选 Skill Catalog。
