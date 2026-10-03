import 'dart:ui';

import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

const v3RetiredKnowledgeFixtureIds = <String>{
  'need',
  'roi',
  'story',
  'case',
  'industry',
  'trend',
  'security',
  'copy',
  'budget',
  'service',
  'signal',
  'pilot-scope',
  'baseline',
  'workflow',
  'delivery-boundary',
  'data-classification',
  'procurement',
  'trial-review',
  'content-method',
  'customer-success',
  'product-roadmap-review',
  'home-renovation-budget-meeting',
  'course-screen-capture',
  'crm-demo-capture',
  'budget-sheet-capture',
  'design-review-capture',
  'travel-booking-capture',
  'sleep-research-link',
  'remote-team-guide-link',
  'personal-finance-link',
  'quarter-reflection-monologue',
  'parenting-monologue',
  'creative-block-monologue',
  'health-habit-note',
  'reading-reflection-note',
  'aggregation-weekly-energy-plan',
  'recruitment-interview-recording',
  'sales-followup-recording',
  'field-research-recording',
  'industry-whitepaper-doc',
  'contract-risk-doc',
  'nutrition-guide-doc',
  'whiteboard-media',
  'museum-media',
  'product-weekly-subscription',
  'knowledge-square-sleep',
  'knowledge-square-language',
  'knowledge-square-budget',
  'hotspot-ai-agent-20260713',
  'hotspot-real-experience-20260712',
};

final v3KnowledgeNotes = <V3FeedItem>[
  V3FeedItem(
    id: 'demo-laozhou-001',
    title: '第一次被客户赶出办公室',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 29, 9),
    rawBody:
        '刚做销售时，我曾把一次客户拒绝理解成对整个人的否定。后来才明白，对方拒绝的只是没有触及问题的表达。把事情和自己分开，拒绝才会变成可以分析和改进的事实。',
    summaryBody: '纲要\n\n客户拒绝的是无关表达，不是一个人的全部价值。',
    topics: const <String>['职场', '销售', '拒绝', '自尊'],
    contentLineId: 'demo-line-work-boundary',
    contentLineName: '职场与边界',
  ),
  V3FeedItem(
    id: 'demo-laozhou-012',
    title: '很多事情不是没有答案，而是答案有代价',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 18, 9),
    rawBody:
        '成年人面对的许多问题并非没有倾向，而是每个答案都要付费。成熟不是找到完全没有损失的路，而是知道自己正在交换什么，并愿意承担选择的后果。',
    summaryBody: '纲要\n\n重要决定要同时看收益、损失和可承担的后果。',
    topics: const <String>['选择', '代价', '责任', '决策'],
    contentLineId: 'demo-line-choice-cost',
    contentLineName: '选择与代价',
  ),
  V3FeedItem(
    id: 'demo-laozhou-021',
    title: '重大决定的四栏分析法',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 9, 9),
    rawBody:
        '面对辞职、转行、创业或结束关系等重大决定，可以分别写下已经确认的事实、自己的感受和解释、每个选项的代价，以及下一步低成本验证动作。方法不能替人决定，但能把情绪、事实和想象分开。',
    summaryBody: '纲要\n\n用事实、感受、代价和验证动作拆解重大决定。',
    topics: const <String>['决策方法', '选择', '风险', '行动'],
    contentLineId: 'demo-line-choice-cost',
    contentLineName: '选择与代价',
  ),
  V3FeedItem(
    id: 'demo-laozhou-029',
    title: '“先看代价”表达笔记',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 1, 9),
    rawBody:
        '“先别急着问对不对，先问代价是什么。”这句话用于把两个选项背后的交换说清楚。它不是阻止行动，而是让人在真实场景之后理解自己愿意承担哪一种困难。',
    summaryBody: '纲要\n\n先看清选择的交换，再把决定交还给当事人。',
    topics: const <String>['口头表达', '选择', '账号语言', '短视频'],
    contentLineId: 'demo-line-choice-cost',
    contentLineName: '选择与代价',
  ),
  V3FeedItem(
    id: 'demo-laozhou-061',
    title: '为什么早晨的菜市场比商场更有生命力',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 5, 30, 9),
    rawBody:
        '商场展示一座城市希望被看见的样子，菜市场展示它每天如何生活。真正让地方有生命力的，往往不是最贵的建筑，而是每天有人使用、交谈并记得彼此的小空间。',
    summaryBody: '纲要\n\n日常交易和重复相遇构成城市真实的生命力。',
    topics: const <String>['城市观察', '菜市场', '生活气息', '商业空间'],
    contentLineId: 'demo-line-daily-life',
    contentLineName: '普通生活观察',
  ),
  V3FeedItem(
    id: 'demo-laozhou-090',
    title: '不相关的笔记，最后也可能成为重要连接',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 5, 1, 9),
    rawBody:
        '真实的人不会只关心一个主题。旧工具箱、修鞋铺、纸质日历和一条街的变化，看似与定位无关，却可能在具体问题中连接经历、判断和创作。不是每条笔记都必须立刻有用。',
    summaryBody: '纲要\n\n保留生活细节，让不同素材在图谱中形成新的连接。',
    topics: const <String>['知识图谱', '内容积累', '创作', '素材'],
    contentLineId: 'demo-line-expression',
    contentLineName: '综合表达',
  ),
  V3FeedItem(
    id: 'knowledge-square-sleep',
    title: '社区睡眠改善实验',
    source: V3MaterialSource.knowledgeSquare,
    ownership: V3NoteOwnership.knowledgeSquare,
    createdAt: DateTime(2026, 6, 4, 22, 20),
    rawBody: '社区成员连续四周记录起床时间、晨间光照和午后咖啡因，观察哪些小改变最容易坚持。个人体验只用于交流，持续症状仍应寻求帮助。',
    summaryBody: '纲要\n\n睡眠实验重视可持续改变，并区分经验分享与医疗建议。',
    topics: const <String>['睡眠', '社区实验', '健康'],
  ),
  V3FeedItem(
    id: 'knowledge-square-language',
    title: '三十天口语练习法',
    source: V3MaterialSource.knowledgeSquare,
    ownership: V3NoteOwnership.knowledgeSquare,
    createdAt: DateTime(2026, 6, 3, 7, 40),
    rawBody: '练习法每天选择一个真实场景，先录一分钟表达，再听回放并只修正一个最影响理解的问题。第二天复用结构并替换情境。',
    summaryBody: '纲要\n\n口语进步来自真实场景、短反馈循环和有控制的重复。',
    topics: const <String>['语言学习', '口语', '练习方法'],
  ),
  V3FeedItem(
    id: 'knowledge-square-budget',
    title: '家庭应急金配置讨论',
    source: V3MaterialSource.knowledgeSquare,
    ownership: V3NoteOwnership.knowledgeSquare,
    createdAt: DateTime(2026, 6, 2, 19, 15),
    rawBody: '讨论根据家庭固定支出、收入稳定性和保险覆盖估算应急金，而不是套用统一月数。应急资金首先保证流动性和安全性。',
    summaryBody: '纲要\n\n应急金规模取决于家庭现金流风险，核心目标是随时可用。',
    topics: const <String>['家庭财务', '应急金', '风险'],
  ),
];

V3FeedItem? v3KnowledgeNoteForId(String id) {
  for (final note in v3KnowledgeNotes) {
    if (note.id == id) return note;
  }
  return null;
}

const v3GraphNodes = <V3GraphNode>[
  V3GraphNode(
    id: 'center',
    label: '内容大脑',
    cluster: V3GraphCluster.viewpoint,
    position: Offset(450, 430),
    summary: '沉淀录音、资料与想法，形成可复用的内容资产。',
    weight: 3.2,
    center: true,
  ),
];
