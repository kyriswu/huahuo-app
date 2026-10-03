import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/api/api_client.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../domain/deep_positioning_models.dart';
import '../domain/positioning_lifecycle.dart';

export '../domain/deep_positioning_models.dart';

// resident-provider: Shares one account-scoped deep positioning repository identity across dependent controllers.
final deepPositioningRepositoryProvider = Provider<DeepPositioningRepository>((
  ref,
) {
  return const UnavailableDeepPositioningRepository();
});

// resident-provider: Preserves the initial positioning report sink dependency identity across route changes.
final initialPositioningReportSinkProvider =
    Provider<InitialPositioningReportSink>((ref) {
      return const _NoopInitialPositioningReportSink();
    });

final v3DemoPersonPositioningResult = DeepPositioningResult(
  markdown: '''# 老周不劝你｜当前定位报告

> 不替你做决定，只陪你把代价看清楚。

## 账号定位

老周（周明远），43 岁。经历过销售、管理、创业失败、家庭关系变化和中年重新开始，用一个普通成年人的真实经验，帮助读者看清选择背后的代价，而不是替别人给出标准答案。

## 服务对象

主要面向 28—45 岁、正处在职场转折、关系变化、经济压力或人生重启阶段的成年人。他们并不缺道理，更需要把事实和情绪分开，识别真正的冲突，再做能承担后果的选择。

## 核心价值

- 把复杂问题拆成事实、情绪、选择和代价。
- 不贩卖焦虑，也不制造轻易成功的幻觉。
- 用亲历故事和日常观察提供可参考的判断过程。
- 尊重每个人的处境，让读者保留自己的决定权。

## 长期内容方向

1. 选择与代价：重要决定之前，真正需要看清什么。
2. 职场与边界：责任、利益、关系和退出时机。
3. 关系与分寸：亲密关系、家庭责任和成年人之间的边界。
4. 金钱与欲望：收入、消费、风险和安全感。
5. 中年与重新开始：失败后的修复、调整和再出发。
6. 普通生活观察：从具体小事中提炼可复用的判断。

## 内容结构与表达

内容优先采用“场景—冲突—判断—代价—行动”的结构。先讲具体发生了什么，再说明矛盾在哪里、自己如何判断、不同选择各自需要承担什么，最后给出一个小而可执行的行动建议。语言保持平稳、自然、克制，少用口号，不端着说教，也不刻意煽情。

## 边界

不包装成功学人设，不承诺唯一答案；涉及医疗、法律、心理健康和投资等专业领域时，只分享个人经验和一般信息，并明确建议寻求专业帮助。

## 当前阶段

人物定位和内容边界已经明确。下一阶段持续从真实笔记中提炼稳定观点、代表性故事和可验证的方法，让账号被记住的不是某个标签，而是一种可靠的判断方式。''',
  savedAt: DateTime.utc(2026, 7, 28, 9),
  isDemo: true,
  initialCompletedAt: DateTime.utc(2026, 6, 1, 9),
  furtherCompletedAt: DateTime.utc(2026, 7, 28, 9),
);

abstract interface class PositioningReportPort {
  bool get isDemo;

  DeepPositioningResult? load();

  Future<DeepPositioningResult?> refresh();

  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  });

  Future<DeepPositioningResult> save(DeepPositioningDraft draft);

  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  });
}

abstract interface class DeepPositioningRepository
    implements PositioningReportPort {}

abstract interface class PositioningReportReadPort {
  Future<PositioningReportRead> readReport();
}

abstract interface class InitialPositioningReportSink {
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  });
}

abstract interface class InitialPositioningFormalReportSink {
  Future<bool> refreshFormalReport();
}

final class _NoopInitialPositioningReportSink
    implements InitialPositioningReportSink {
  const _NoopInitialPositioningReportSink();

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async => true;
}

abstract interface class DeepPositioningRemotePort {
  Future<DeepPositioningResult?> loadReport();
}

final class WorkspaceProfileDeepPositioningRemote
    implements DeepPositioningRemotePort {
  const WorkspaceProfileDeepPositioningRemote({
    required WorkspaceLifecycleClient workspaceClient,
    required String workspaceId,
    bool Function()? isCurrent,
    DateTime Function()? now,
  }) : _workspaceClient = workspaceClient,
       _workspaceId = workspaceId,
       _isCurrent = isCurrent,
       _now = now;

  final WorkspaceLifecycleClient _workspaceClient;
  final String _workspaceId;
  final bool Function()? _isCurrent;
  final DateTime Function()? _now;

  @override
  Future<DeepPositioningResult?> loadReport() async {
    if (_isCurrent?.call() == false)
      throw StateError('POSITIONING_SCOPE_CHANGED');
    final response = await _workspaceClient.currentProfile();
    if (_isCurrent?.call() == false)
      throw StateError('POSITIONING_SCOPE_CHANGED');
    if (!response.ok || response.data == null) {
      throw StateError(
        response.error?.code ?? 'DEEP_POSITIONING_PROFILE_READ_FAILED',
      );
    }
    final fields = response.data!.fields;
    if (fields['workspaceId'] != _workspaceId) {
      throw StateError('POSITIONING_WORKSPACE_MISMATCH');
    }
    final fallback = (_now ?? DateTime.now)().toUtc();
    return workspaceProfilePositioningReport(fields, fallback: fallback);
  }
}

DeepPositioningResult? workspaceProfilePositioningReport(
  Map<String, Object?> fields, {
  required DateTime fallback,
}) {
  final markdown = _remotePositioningMarkdown(fields);
  if (markdown == null) return null;
  final savedAt = _parseReportTimestamp(fields['updatedAt']) ?? fallback;
  final structuredProgress = parsePositioningProgressPayload(
    fields['positioningProgress'],
  );
  final progress =
      structuredProgress ?? parseLatestPositioningProgress(markdown);
  return DeepPositioningResult(
    markdown: _clientPositioningMarkdown(markdown),
    savedAt: savedAt,
    initialCompletedAt: savedAt,
    progress: progress,
    serverPositioningStage: _remotePositioningStage(
      fields,
      progress: structuredProgress,
    ),
    formalVerified: true,
    formalContentDigest: positioningContentDigest(markdown),
  );
}

final class UnavailableDeepPositioningRepository
    implements DeepPositioningRepository {
  const UnavailableDeepPositioningRepository();

  @override
  bool get isDemo => false;

  @override
  DeepPositioningResult? load() => null;

  @override
  Future<DeepPositioningResult?> refresh() async => null;

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async => throw StateError('DEEP_POSITIONING_BACKEND_UNAVAILABLE');

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) async =>
      throw StateError('DEEP_POSITIONING_BACKEND_UNAVAILABLE');

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async => throw StateError('DEEP_POSITIONING_BACKEND_UNAVAILABLE');
}

final class DeepPositioningMockRepository implements DeepPositioningRepository {
  const DeepPositioningMockRepository({
    this.delay = const Duration(milliseconds: 650),
    this.fail = false,
  });

  final Duration delay;
  final bool fail;

  @override
  bool get isDemo => true;

  @override
  DeepPositioningResult? load() => null;

  @override
  Future<DeepPositioningResult?> refresh() async => load();

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    final normalized = _clientPositioningMarkdown(markdown);
    if (normalized.isEmpty) {
      throw ArgumentError.value(markdown, 'markdown', 'must not be empty');
    }
    final timestamp = savedAt.toUtc();
    return DeepPositioningResult(
      markdown: normalized,
      savedAt: timestamp,
      isDemo: true,
      initialCompletedAt: timestamp,
    );
  }

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('DEEP_POSITIONING_SAVE_FAILED');
    return _buildDemoResult(draft, DateTime.now());
  }

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('DEEP_POSITIONING_SAVE_FAILED');
    final now = DateTime.now();
    final generated = _buildConversationResult(entries, now);
    return DeepPositioningResult(
      markdown: generated.markdown,
      savedAt: now,
      isDemo: true,
      initialCompletedAt: now,
      furtherCompletedAt: further ? now : null,
    );
  }
}

final class PersistentDeepPositioningMockRepository
    implements DeepPositioningRepository {
  PersistentDeepPositioningMockRepository({
    required AppPreferencesDao dao,
    required String userScope,
    DateTime Function()? now,
    DeepPositioningResult? seedResult,
    this.delay = const Duration(milliseconds: 650),
    this.fail = false,
  }) : // Public parameter names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _dao = dao,
       _preferenceKey = 'positioning.report.${_scopeHash(userScope)}',
       // Public callers should not need to pass a private named parameter.
       // ignore: prefer_initializing_formals
       _seedResult = seedResult,
       _now = now ?? DateTime.now;

  final AppPreferencesDao _dao;
  final String _preferenceKey;
  final DeepPositioningResult? _seedResult;
  final DateTime Function() _now;
  final Duration delay;
  final bool fail;

  @override
  bool get isDemo => true;

  @visibleForTesting
  String get preferenceKey => _preferenceKey;

  @override
  DeepPositioningResult? load() {
    return _decodePersistedReport(
      _dao.readValue(_preferenceKey),
      isDemo: true,
      fallback: _seedResult,
    );
  }

  @override
  Future<DeepPositioningResult?> refresh() async => load();

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    final normalized = _clientPositioningMarkdown(markdown);
    if (normalized.isEmpty) {
      throw ArgumentError.value(markdown, 'markdown', 'must not be empty');
    }
    final timestamp = savedAt.toUtc();
    final previous = load();
    final result = DeepPositioningResult(
      markdown: normalized,
      savedAt: timestamp,
      isDemo: true,
      initialCompletedAt: previous?.initialCompletedAt ?? timestamp,
      furtherCompletedAt: previous?.furtherCompletedAt,
      progress: parseLatestPositioningProgress(normalized),
    );
    _persist(result);
    return result;
  }

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('DEEP_POSITIONING_SAVE_FAILED');
    final result = _buildDemoResult(draft, _now());
    _persist(result);
    return result;
  }

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('DEEP_POSITIONING_SAVE_FAILED');
    final now = _now();
    final previous = load();
    final generated = _buildConversationResult(entries, now);
    final result = DeepPositioningResult(
      markdown: generated.markdown,
      savedAt: now,
      isDemo: true,
      initialCompletedAt: previous?.initialCompletedAt ?? now,
      furtherCompletedAt: further
          ? previous?.furtherCompletedAt ?? now
          : previous?.furtherCompletedAt,
    );
    _persist(result);
    return result;
  }

  void _persist(DeepPositioningResult result) {
    _persistReport(_dao, _preferenceKey, result);
  }
}

final class PersistentDeepPositioningRepository
    implements DeepPositioningRepository, PositioningReportReadPort {
  PersistentDeepPositioningRepository({
    required AppPreferencesDao dao,
    required String userScope,
    DeepPositioningRemotePort? remote,
  }) : _dao = dao,
       _preferenceKey = 'positioning.report.${_scopeHash(userScope)}',
       _remote = remote;

  final AppPreferencesDao _dao;
  final String _preferenceKey;
  final DeepPositioningRemotePort? _remote;

  @override
  bool get isDemo => false;

  @visibleForTesting
  String get preferenceKey => _preferenceKey;

  @override
  DeepPositioningResult? load() => _formalPositioningReport(
    _decodePersistedReport(_dao.readValue(_preferenceKey), isDemo: false),
  );

  @override
  Future<DeepPositioningResult?> refresh() async {
    return (await readReport()).report;
  }

  @override
  Future<PositioningReportRead> readReport() async {
    final cached = load();
    final remote = _remote;
    try {
      if (remote == null) throw StateError('POSITIONING_REMOTE_UNAVAILABLE');
      final recovered = _formalPositioningReport(
        _clientPositioningResult(
          await remote.loadReport(),
          formalVerified: true,
        ),
      );
      if (recovered != null) {
        _persist(recovered);
        return PositioningReportRead(
          PositioningReportOrigin.remote,
          report: recovered,
        );
      }
      return PositioningReportRead(
        PositioningReportOrigin.absent,
        report: cached,
      );
    } catch (_) {
      return PositioningReportRead(
        cached == null
            ? PositioningReportOrigin.unavailable
            : cached.formalVerified
            ? PositioningReportOrigin.verifiedCache
            : PositioningReportOrigin.legacyCache,
        report: cached,
        errorCode: 'POSITIONING_REPORT_READ_FAILED',
      );
    }
  }

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    final normalized = _clientPositioningMarkdown(markdown);
    if (normalized.isEmpty) {
      throw ArgumentError.value(markdown, 'markdown', 'must not be empty');
    }
    final timestamp = savedAt.toUtc();
    final previous = load();
    final result = DeepPositioningResult(
      markdown: normalized,
      savedAt: timestamp,
      initialCompletedAt: previous?.initialCompletedAt ?? timestamp,
      furtherCompletedAt: previous?.furtherCompletedAt,
      progress: parseLatestPositioningProgress(normalized),
    );
    _persist(result);
    return result;
  }

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) async =>
      throw StateError('DEEP_POSITIONING_BACKEND_UNAVAILABLE');

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async => throw StateError('DEEP_POSITIONING_BACKEND_UNAVAILABLE');

  void _persist(DeepPositioningResult result) {
    _persistReport(_dao, _preferenceKey, result);
  }
}

DeepPositioningResult? _formalPositioningReport(DeepPositioningResult? result) {
  if (result == null ||
      result.markdown.trim().isEmpty ||
      result.initialCompletedAt != null) {
    return result;
  }
  return DeepPositioningResult(
    markdown: result.markdown,
    savedAt: result.savedAt,
    isDemo: result.isDemo,
    initialCompletedAt: result.savedAt,
    furtherCompletedAt: result.furtherCompletedAt,
    progress: result.progress,
    serverPositioningStage: result.serverPositioningStage,
    formalVerified: result.formalVerified,
    formalContentDigest: result.formalContentDigest,
  );
}

DeepPositioningResult? _clientPositioningResult(
  DeepPositioningResult? result, {
  bool? formalVerified,
}) {
  if (result == null) return null;
  final markdown = _clientPositioningMarkdown(result.markdown);
  if (markdown.isEmpty) return null;
  return DeepPositioningResult(
    markdown: markdown,
    savedAt: result.savedAt,
    isDemo: result.isDemo,
    initialCompletedAt: result.initialCompletedAt,
    furtherCompletedAt: result.furtherCompletedAt,
    progress: result.progress,
    serverPositioningStage: result.serverPositioningStage,
    formalVerified: formalVerified ?? result.formalVerified,
    formalContentDigest:
        result.formalContentDigest ??
        ((formalVerified ?? result.formalVerified)
            ? positioningContentDigest(result.markdown)
            : null),
  );
}

DeepPositioningResult? _decodePersistedReport(
  String? raw, {
  required bool isDemo,
  DeepPositioningResult? fallback,
}) {
  if (raw == null) return fallback;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final markdown = decoded['markdown'];
    final savedAt = decoded['saved_at'];
    final initialCompletedAt = decoded['initial_completed_at'];
    final furtherCompletedAt = decoded['further_completed_at'];
    final progress = parsePositioningProgressPayload(decoded['progress']);
    final serverPositioningStage = decoded['server_positioning_stage'];
    if (markdown is! String || markdown.trim().isEmpty || savedAt is! String) {
      return null;
    }
    final parsedSavedAt = DateTime.tryParse(savedAt)?.toUtc();
    if (parsedSavedAt == null) return null;
    return DeepPositioningResult(
      markdown: _clientPositioningMarkdown(markdown),
      savedAt: parsedSavedAt,
      isDemo: isDemo,
      formalVerified: decoded['formal_verified'] == true,
      formalContentDigest: decoded['formal_content_digest'] as String?,
      initialCompletedAt: initialCompletedAt is String
          ? DateTime.tryParse(initialCompletedAt)?.toUtc()
          : decoded.containsKey('initial_completed_at')
          ? null
          : parsedSavedAt,
      furtherCompletedAt: furtherCompletedAt is String
          ? DateTime.tryParse(furtherCompletedAt)?.toUtc()
          : null,
      progress: progress,
      serverPositioningStage:
          serverPositioningStage is int &&
              serverPositioningStage >= 0 &&
              serverPositioningStage <= 2
          ? serverPositioningStage
          : null,
    );
  } catch (_) {
    return null;
  }
}

void _persistReport(
  AppPreferencesDao dao,
  String preferenceKey,
  DeepPositioningResult result,
) {
  dao.upsertValue(
    preferenceKey: preferenceKey,
    value: jsonEncode(<String, Object?>{
      'markdown': result.markdown,
      'formal_verified': result.formalVerified,
      if (result.formalContentDigest != null)
        'formal_content_digest': result.formalContentDigest,
      'saved_at': result.savedAt.toUtc().toIso8601String(),
      'initial_completed_at': result.initialCompletedAt
          ?.toUtc()
          .toIso8601String(),
      'further_completed_at': result.furtherCompletedAt
          ?.toUtc()
          .toIso8601String(),
      if (result.progress != null)
        'progress': positioningProgressProfileToPayload(result.progress!),
      if (result.serverPositioningStage != null)
        'server_positioning_stage': result.serverPositioningStage,
    }),
    updatedAt: result.savedAt.toUtc().toIso8601String(),
  );
}

String? _remotePositioningMarkdown(Map<String, Object?> fields) {
  final positioning = fields['positioning'];
  if (positioning is String && positioning.trim().isNotEmpty) {
    final normalized = _clientPositioningMarkdown(positioning);
    if (normalized.isNotEmpty) return positioning;
  }
  final conclusions = fields['conclusions'];
  if (conclusions is! List) return null;
  for (final entry in conclusions) {
    if (entry is! Map) continue;
    final profileKind = entry['profileKind'];
    final markdown = entry['markdown'];
    if (profileKind == 'positioning' &&
        markdown is String &&
        markdown.trim().isNotEmpty) {
      final normalized = _clientPositioningMarkdown(markdown);
      if (normalized.isNotEmpty) return markdown;
    }
  }
  return null;
}

int _remotePositioningStage(
  Map<String, Object?> fields, {
  PositioningProgressProfile? progress,
}) {
  final raw = fields['positioningProgress'];
  if (raw is Map) {
    final stage = raw['positioningStage'];
    if (stage is int && stage >= 0 && stage <= 2) return stage;
    if (raw['consultingCompleted'] == true) return 2;
    if (raw['coldStartCompleted'] == true) return 1;
  }
  if (fields['basicPositioningCompleted'] == true ||
      progress?.coldStartCompleted == true) {
    return 1;
  }
  return 0;
}

String _clientPositioningMarkdown(String markdown) =>
    stripPositioningReportFrontmatter(markdown).trim();

DateTime? _parseReportTimestamp(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

DeepPositioningResult _buildDemoResult(
  DeepPositioningDraft draft,
  DateTime savedAt,
) {
  return DeepPositioningResult(
    savedAt: savedAt,
    isDemo: true,
    markdown:
        '''## 账号定位

你是一位${draft.identity.trim()}，长期关注${draft.industry.trim()}，擅长${draft.expertise.trim()}。

## 服务对象

面向${draft.targetAudience.trim()}。

## 核心价值

帮助他们${draft.value.trim()}。

## 内容方向

建议长期围绕“${draft.accountGoal.trim()}”分享方法、真实经历和可验证案例。''',
  );
}

DeepPositioningResult _buildConversationResult(
  List<DeepPositioningConversationEntry> entries,
  DateTime savedAt,
) {
  final normalized = <DeepPositioningConversationEntry>[
    for (final entry in entries)
      if (entry.text.trim().isNotEmpty)
        DeepPositioningConversationEntry(
          text: String.fromCharCodes(entry.text.trim().runes.take(600)),
          isAssistant: entry.isAssistant,
        ),
  ];
  if (normalized.isEmpty) {
    throw ArgumentError.value(entries, 'entries', 'conversation is empty');
  }
  final start = normalized.length > 12 ? normalized.length - 12 : 0;
  final bounded = normalized.sublist(start);
  final userAnswers = bounded
      .where((entry) => !entry.isAssistant)
      .map((entry) => entry.text)
      .toList(growable: false);
  String? latestAssistant;
  for (final entry in bounded) {
    if (entry.isAssistant) latestAssistant = entry.text;
  }
  final markdown = StringBuffer('## 当前定位线索\n\n');
  if (userAnswers.isEmpty) {
    markdown.writeln('定位对话已经开始，继续回答 AI 的问题以补充真实线索。');
  } else {
    for (final answer in userAnswers) {
      markdown.writeln('- $answer');
    }
  }
  markdown.write('\n## AI 定位进展\n\n');
  markdown.writeln(latestAssistant ?? 'AI 正在根据你的回答继续追问，定位结论会随对话更新。');
  markdown.write('\n## 下一步\n\n继续在定位对话中补充经历、优势、服务对象和目标。');
  return DeepPositioningResult(
    markdown: markdown.toString(),
    savedAt: savedAt,
    isDemo: true,
  );
}

String _scopeHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final unit in value.trim().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
