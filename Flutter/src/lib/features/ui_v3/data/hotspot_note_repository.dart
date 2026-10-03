import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../notifications/domain/notification_models.dart';
import '../domain/feed_item_models.dart';

// resident-provider: Shares one account-scoped hotspot note repository identity across dependent controllers.
final hotspotNoteRepositoryProvider = Provider<HotspotNoteRepository>((ref) {
  return const UnavailableHotspotNoteRepository();
});

abstract interface class HotspotNoteRepository {
  Future<List<V3FeedItem>> loadHotspots();
}

final class ApiHotspotNoteRepository implements HotspotNoteRepository {
  ApiHotspotNoteRepository(this._apiClient, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ApiClient _apiClient;
  final DateTime Function() _now;

  @override
  Future<List<V3FeedItem>> loadHotspots() async {
    final result = await _apiClient.request<List<V3FeedItem>>(
      ApiRequestOptions<List<V3FeedItem>>(
        endpointId: 'home',
        parseData: (value) {
          final parsed = parseHomeHotspotNotes(value, now: _now());
          if (parsed == null) {
            throw const FormatException('Invalid Home hotspot payload');
          }
          return parsed;
        },
      ),
    );
    if (!result.ok) {
      throw StateError(result.error?.code ?? 'HOTSPOT_NOTES_LOAD_FAILED');
    }
    return result.data!;
  }
}

List<V3FeedItem>? parseHomeHotspotNotes(
  Object? value, {
  required DateTime now,
}) {
  final home = asObjectMap(value);
  final rawSuggestion = home?['hotspotSuggestion'];
  final suggestion = asObjectMap(rawSuggestion);
  if (home == null || suggestion == null) return null;
  if (suggestion.isEmpty) return const <V3FeedItem>[];

  final id = _homeOpaqueIdentifier(suggestion['suggestionId']);
  final title = _homeText(suggestion['title'], maxLength: 160);
  final summary = _homeText(suggestion['summary'], maxLength: 1200);
  final eventBrief = _homeText(suggestion['eventBrief'], maxLength: 3000);
  if (id == null || title == null || (summary == null && eventBrief == null)) {
    return null;
  }

  final detail = asObjectMap(suggestion['hotspotDetail']);
  final discussionPoints = _homeTextList(
    suggestion['discussionPoints'] ?? detail?['discussionPoints'],
  );
  final topicAngles = _homeTextList(
    suggestion['topicAngles'] ?? detail?['topicAngles'],
  );
  final sourceName = _homeText(suggestion['sourceName'], maxLength: 64);
  final createdAt =
      _homeDate(suggestion['createdAt']) ??
      _homeDate(home['serverTime']) ??
      now.toUtc();
  final updatedAt = _homeDate(suggestion['updatedAt']) ?? createdAt;
  final body = _homeHotspotMarkdown(
    summary: summary,
    eventBrief: eventBrief,
    discussionPoints: discussionPoints,
    topicAngles: topicAngles,
  );
  final topics = <String>[
    if (sourceName != null) sourceName,
    for (final angle in topicAngles.take(2))
      if (angle.length <= 32) angle,
  ];

  return <V3FeedItem>[
    V3FeedItem(
      id: id,
      title: title,
      source: V3MaterialSource.hotspot,
      ownership: V3NoteOwnership.hotspot,
      createdAt: createdAt,
      updatedAt: updatedAt,
      rawBody: body,
      summaryBody: summary ?? eventBrief,
      topics: List<String>.unmodifiable(topics),
      syncState: NoteSyncState.synced,
    ),
  ];
}

String _homeHotspotMarkdown({
  required String? summary,
  required String? eventBrief,
  required List<String> discussionPoints,
  required List<String> topicAngles,
}) {
  final sections = <String>[
    if (eventBrief != null) '## 事件概览\n\n$eventBrief',
    if (summary != null && summary != eventBrief) '## 推荐摘要\n\n$summary',
    if (discussionPoints.isNotEmpty)
      '## 讨论要点\n\n${discussionPoints.map((item) => '- $item').join('\n')}',
    if (topicAngles.isNotEmpty)
      '## 内容角度\n\n${topicAngles.map((item) => '- $item').join('\n')}',
  ];
  final markdown = sections.join('\n\n');
  return markdown.length <= 12000 ? markdown : markdown.substring(0, 12000);
}

String? _homeText(Object? value, {required int maxLength}) {
  if (value is! String) return null;
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
      .trim();
  if (normalized.isEmpty) return null;
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

String? _homeOpaqueIdentifier(Object? value) {
  final normalized = value is String ? value.trim() : null;
  return normalized != null && isSafeNotificationOpaqueIdentifier(normalized)
      ? normalized
      : null;
}

List<String> _homeTextList(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final item in value.take(12))
      if (_homeText(item, maxLength: 300) case final text?) text,
  ];
}

DateTime? _homeDate(Object? value) {
  final raw = _homeText(value, maxLength: 64);
  return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

final class UnavailableHotspotNoteRepository implements HotspotNoteRepository {
  const UnavailableHotspotNoteRepository();

  @override
  Future<List<V3FeedItem>> loadHotspots() async =>
      throw StateError('HOTSPOT_NOTES_BACKEND_UNAVAILABLE');
}

final class HotspotNoteMockRepository implements HotspotNoteRepository {
  HotspotNoteMockRepository({
    this.delay = const Duration(milliseconds: 120),
    this.fail = false,
    this.overrideNotes,
  });

  final Duration delay;
  final bool fail;
  final List<V3FeedItem>? overrideNotes;

  @override
  Future<List<V3FeedItem>> loadHotspots() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('HOTSPOT_NOTES_LOAD_FAILED');
    return List<V3FeedItem>.of(overrideNotes ?? _defaultHotspotNotes());
  }
}

List<V3FeedItem> _defaultHotspotNotes() => <V3FeedItem>[
  _hotspot(
    id: 'hotspot-ai-agent-20260713',
    title: 'AI Agent 正在重塑普通人的工作方式',
    createdAt: DateTime(2026, 7, 13, 9),
    rawBody: '''## 从回答问题到完成任务

AI Agent 的变化不只是回答更长，而是能够在一个明确目标下连续执行多个步骤。它可以整理资料、生成初稿、核对结果，再把异常项交还给人处理。这种转变让 AI 从“随时可问的工具”变成“可以协作的执行者”。

## 普通人真正需要准备的东西

有价值的不是记住更多工具名称，而是把自己的经验拆成可检查的工作流程：什么条件下开始，需要哪些输入，中间怎样判断，什么结果才算完成。只有当这些标准被说清楚，Agent 才能稳定地接手重复任务。

## 先从一件小事开始

选择一件每周都要做、结果又容易验证的事，记录人工执行时的关键判断，再让 Agent 先完成其中一段。小范围、有验收、能回退，比一开始就追求全自动更容易产生持续价值。''',
    summaryBody:
        'AI Agent 的价值正在从单次回答转向持续执行任务。对普通人而言，真正值得关注的不是工具数量，而是如何把自己的经验整理成可以被 AI 调用的工作流程。',
    topics: const <String>['AI Agent', '工作方式'],
  ),
  _hotspot(
    id: 'hotspot-real-experience-20260712',
    title: '内容平台开始重新重视真实经验',
    createdAt: DateTime(2026, 7, 12, 9),
    rawBody: '''## 真实经验为什么重新变得稀缺

当通用知识可以被快速整理，单纯复述信息已经很难建立信任。读者更关心一件事发生在什么环境、当事人面临过哪些选择，以及最后的结果是否验证了当时的判断。

## 经验不等于讲故事

一条有用的经验内容需要同时交代背景、行动和边界。背景说明问题为什么出现，行动呈现关键取舍，边界则提醒读者这个方法在什么条件下可能失效。这些细节让别人能够判断，而不是只能相信。

## 把经验变成可用内容

复盘时不妨记下三个问题：我当时知道什么，为什么做这个选择，后来哪个事实证明我对了或错了。当判断过程被保留，一次经历才会成为能被他人使用的内容资产。''',
    summaryBody:
        '当大量内容都能被快速生成后，真实经历、具体判断和可验证案例变得更有价值。创作者需要把个人经验转化为别人能够理解和使用的内容。',
    topics: const <String>['真实经验', '内容趋势'],
  ),
  _hotspot(
    id: 'hotspot-ai-workflows-20260711',
    title: 'AI 协作正在进入可复盘阶段',
    createdAt: DateTime(2026, 7, 11, 10),
    rawBody: '''## AI 协作开始需要复盘

团队已经不满足于展示一次性的 AI 结果，而是开始问：这个结果是怎样产生的，哪一步最容易失败，出问题时能不能回到上一个可用状态。只有回答这些问题，AI 才能进入日常流程。

## 为每一步设置验收点

一个可复盘的流程会记录输入来源、使用的指令、产出版本和人工确认结果。验收点不需要复杂，但必须能明确区分“可以继续”和“应该停止”。这会大幅降低错误在后续步骤中被放大的概率。

## 复盘的目标是修改流程

复盘不是统计 AI 做了多少工作，而是找到哪些判断应该留给人，哪些输入应该更结构化，以及哪些失败可以提前被发现。每次只改一个环节，工作流才会越来越稳定。''',
    summaryBody: 'AI 协作的重点正在从得到答案，转向建立可检查、可回退、可复盘的工作步骤。',
    topics: const <String>['AI 协作', '工作流'],
  ),
  _hotspot(
    id: 'hotspot-small-team-20260710',
    title: '小团队先把经验做成可复用的 SOP',
    createdAt: DateTime(2026, 7, 10, 11),
    rawBody: '''## 小团队的效率差距在哪里

小团队往往不缺能力，缺的是经验能否被别人接手。当任务一忙，大量判断依赖临时语音、私聊和个人记忆，同一个问题就会被反复解决。工具再多，也无法替代对关键经验的整理。

## SOP 首先要保留判断

好的 SOP 不是把每个动作都写得很细，而是告诉执行者遇到不同情况时应该如何选择。它至少要包含目标、必需输入、关键检查点、异常处理和完成标准。这些信息才能让新成员不依赖原作者也能开始。

## 先处理高频交接

选择一件每周都发生、又经常需要两个人交接的任务。跟随一次真实执行记录下来，让下一个执行者试用，再根据卡住的地方补充。可复用的 SOP 是用出来的，不是一次写完的。''',
    summaryBody: '经验沉淀应优先覆盖高频协作场景，再逐步形成可交接、可复用的团队 SOP。',
    topics: const <String>['组织管理', 'SOP'],
  ),
  _hotspot(
    id: 'hotspot-content-trust-20260709',
    title: '用户开始分辨信息与可验证的判断',
    createdAt: DateTime(2026, 7, 9, 10),
    rawBody: '''## 信息和判断的价值正在分开

信息变得随手可得之后，读者不再因为“知道一件事”就信任作者。他们会进一步判断：这个结论基于什么，是否忽略了反例，在我的情况下还能不能成立。能回答这些问题的内容，才会有持续价值。

## 可验证的判断包含什么

它需要给出具体事实、判断过程和适用边界。事实让读者知道作者看到了什么，过程说明为什么从这些事实得到结论，边界则说明哪些条件变化后需要重新判断。

## 写作时给读者留出核对空间

在结论之外，补充一个真实案例、一个未能验证的假设，以及一个可能推翻当前判断的条件。内容不必显得毫无疑问，透明地呈现不确定性，反而更容易建立信任。''',
    summaryBody: '内容信任来自判断过程、适用边界和可被复核的案例，而不是信息数量。',
    topics: const <String>['内容信任', '真实经验'],
  ),
  _hotspot(
    id: 'hotspot-video-insight-20260708',
    title: '短视频创作开始回到问题解决本身',
    createdAt: DateTime(2026, 7, 8, 10),
    rawBody: '''## 短视频重新回到问题本身

观众愿意停留，并不只是因为剪辑更快、画面更密。更稳定的吸引力来自一个明确问题：谁正在遇到它，它为什么难，视频能不能在有限时间内给出一个可以立即理解的判断或行动。

## 用案例代替空泛模板

一个有效案例应该包含问题出现时的场景、当事人做过的错误尝试、最关键的取舍和最终结果。观众看到过程，才能理解方法为什么有效，也能判断它是否适合自己。

## 结构应该服务于理解

开头说清问题和利益，中段呈现关键判断，结尾给出一个可执行的下一步。节奏、字幕和镜头都应该帮助观众看清这条逻辑，而不是用来遮盖内容本身没有解决问题。''',
    summaryBody: '短视频需要把真实问题、关键判断和可复用的方法讲完整，才能形成长期内容资产。',
    topics: const <String>['视频创作', '问题解决'],
  ),
];

V3FeedItem _hotspot({
  required String id,
  required String title,
  required DateTime createdAt,
  required String rawBody,
  required String summaryBody,
  required List<String> topics,
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: V3MaterialSource.hotspot,
    ownership: V3NoteOwnership.hotspot,
    createdAt: createdAt,
    updatedAt: createdAt,
    rawBody: rawBody,
    summaryBody: summaryBody,
    topics: topics,
  );
}
