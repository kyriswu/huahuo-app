import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/desktop_topics_port.dart';

export '../domain/desktop_topics_port.dart';

final class LocalDesktopTopicsCache implements DesktopTopicsCache {
  LocalDesktopTopicsCache({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _schemaVersion = 2;
  static const _legacySchemaVersion = 1;
  final Future<Directory> Function() _supportDirectory;

  @override
  Future<DesktopTopicsCacheSnapshot> load({
    required String userId,
    required String workspaceId,
  }) async {
    try {
      final file = await _fileFor(userId: userId, workspaceId: workspaceId);
      if (!await file.exists()) return const DesktopTopicsCacheSnapshot();
      final decoded = jsonDecode(await file.readAsString());
      final root = _map(decoded);
      final schemaVersion = root?['schemaVersion'];
      if (root == null ||
          (schemaVersion != _schemaVersion &&
              schemaVersion != _legacySchemaVersion)) {
        return const DesktopTopicsCacheSnapshot();
      }
      final recommendation = _recommendation(root['dailyRecommendation']);
      final collisionRun =
          _topicCollisionRun(root['topicCollisionRun'], workspaceId) ??
          _legacyTopicCollisionRun(_id(root['topicCollisionRunId']));
      return DesktopTopicsCacheSnapshot(
        dailyRecommendation: recommendation,
        dailyExpiresAt: _time(root['dailyExpiresAt']),
        dailyTopicContextsByThread: _dailyTopicContexts(
          root['dailyTopicContexts'],
        ),
        topicCollisionRun: collisionRun,
        topicCollisionCreatedAt: _time(root['topicCollisionCreatedAt']),
      );
    } on Object {
      return const DesktopTopicsCacheSnapshot();
    }
  }

  @override
  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopTopicsCacheSnapshot snapshot,
  }) async {
    final file = await _fileFor(userId: userId, workspaceId: workspaceId);
    final directory = file.parent;
    if (!await directory.exists()) await directory.create(recursive: true);
    final pending = File('${file.path}.part');
    if (await pending.exists()) await pending.delete();
    final dailyTopicContexts = _dailyTopicContexts(
      snapshot.dailyTopicContextsByThread,
    );
    await pending.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': _schemaVersion,
        if (snapshot.dailyRecommendation != null)
          'dailyRecommendation': _recommendationJson(
            snapshot.dailyRecommendation!,
          ),
        if (snapshot.dailyExpiresAt != null)
          'dailyExpiresAt': snapshot.dailyExpiresAt!.toUtc().toIso8601String(),
        if (dailyTopicContexts.isNotEmpty)
          'dailyTopicContexts': dailyTopicContexts,
        if (snapshot.topicCollisionRun != null)
          'topicCollisionRun': _topicCollisionRunJson(
            snapshot.topicCollisionRun!,
          ),
        if (snapshot.topicCollisionRun != null)
          'topicCollisionRunId':
              snapshot.topicCollisionRun!.topicCollisionRunId,
        if (snapshot.topicCollisionCreatedAt != null)
          'topicCollisionCreatedAt': snapshot.topicCollisionCreatedAt!
              .toUtc()
              .toIso8601String(),
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await pending.rename(file.path);
  }

  @override
  Future<void> clear({
    required String userId,
    required String workspaceId,
  }) async {
    final file = await _fileFor(userId: userId, workspaceId: workspaceId);
    if (await file.exists()) await file.delete();
  }

  Future<File> _fileFor({
    required String userId,
    required String workspaceId,
  }) async {
    final user = _requireId(userId);
    final workspace = _requireId(workspaceId);
    final directory = await _supportDirectory();
    final scope = base64Url
        .encode(utf8.encode('$user|$workspace'))
        .replaceAll('=', '');
    return File('${directory.path}${Platform.pathSeparator}topics-$scope.json');
  }
}

Map<String, Object?> _topicCollisionRunJson(TopicCollisionRun run) =>
    <String, Object?>{
      ...run.toJson(),
      'sources': <Object?>[
        for (final source in run.sources)
          <String, Object?>{
            'inputRef': source.inputRef,
            if (source.title?.trim().isNotEmpty == true)
              'title': source.title!.trim(),
          },
      ],
      if (run.outputNoteId != null) 'outputNoteId': run.outputNoteId,
      if (run.failureCode != null) 'failureCode': run.failureCode,
    };

TopicCollisionRun? _topicCollisionRun(Object? value, String workspaceId) {
  final json = _map(value);
  if (json == null) return null;
  try {
    final run = TopicCollisionRun.fromJson({
      ...json,
      'workspaceId': json['workspaceId'] ?? workspaceId,
      'stage': (json['stage'] as String?)?.isNotEmpty == true
          ? json['stage']
          : 'restored',
      'attempt': json['attempt'] ?? 0,
      'maxAttempts': json['maxAttempts'] ?? 3,
      'retryable': json['retryable'] ?? false,
    });
    return TopicCollisionRun(
      topicCollisionRunId: run.topicCollisionRunId,
      workspaceId: run.workspaceId,
      status: run.status,
      stage: run.stage,
      selectedNoteCount: run.selectedNoteCount,
      attempt: run.attempt,
      maxAttempts: run.maxAttempts,
      retryable: run.retryable,
      failureCode: run.failureCode,
      failureStage: run.failureStage,
      outputNoteId: run.outputNoteId,
      sources: json['sources'] is List
          ? List.unmodifiable(
              (json['sources'] as List).map(
                (source) => TopicCollisionSource.fromJson(
                  Map<String, Object?>.from(source as Map),
                ),
              ),
            )
          : const [],
    );
  } on Object {
    return null;
  }
}

TopicCollisionRun? _legacyTopicCollisionRun(String? runId) {
  if (runId == null) return null;
  return TopicCollisionRun(
    topicCollisionRunId: runId,
    status: 'running',
    selectedNoteCount: 4,
    sources: const <TopicCollisionSource>[],
  );
}

Map<String, Object?> _recommendationJson(DailyTopicRecommendation item) =>
    <String, Object?>{
      'recommendationId': item.recommendationId,
      'workspaceId': item.workspaceId,
      'businessDate': item.businessDate,
      'recommendationKind': item.recommendationKind,
      'status': item.status,
      'title': item.title,
      'summaryMarkdown': item.summaryMarkdown,
      'etag': item.etag,
      if (item.generatedAt != null)
        'generatedAt': item.generatedAt!.toUtc().toIso8601String(),
      if (item.readAt != null) 'readAt': item.readAt!.toUtc().toIso8601String(),
      if (item.dismissedAt != null)
        'dismissedAt': item.dismissedAt!.toUtc().toIso8601String(),
      if (item.expiresAt != null)
        'expiresAt': item.expiresAt!.toUtc().toIso8601String(),
      'topics': <Object?>[
        for (final topic in item.topics)
          <String, Object?>{
            'topicId': topic.topicId,
            'title': topic.title,
            'briefMarkdown': topic.briefMarkdown,
            'sourceRefs': <Object?>[
              for (final source in topic.sourceRefs)
                <String, Object?>{
                  'kind': 'daily_hotspot',
                  'hotspotId': source.hotspotId,
                  if (source.label != null) 'label': source.label,
                },
            ],
          },
      ],
    };

DailyTopicRecommendation? _recommendation(Object? value) {
  final json = _map(value);
  if (json == null) return null;
  try {
    return DailyTopicRecommendation.fromJson(json);
  } on FormatException {
    return null;
  }
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) return null;
    result[key] = entry.value;
  }
  return result;
}

DateTime? _time(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String? _id(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return _safeId.hasMatch(normalized) ? normalized : null;
}

Map<String, String> _dailyTopicContexts(Object? value) {
  if (value is! Map) return const <String, String>{};
  final contexts = <String, String>{};
  for (final entry in value.entries) {
    final rawThreadId = entry.key;
    final rawTitle = entry.value;
    if (rawThreadId is! String || rawTitle is! String) continue;
    final threadId = _id(rawThreadId);
    final title = _dailyTopicTitle(rawTitle);
    if (threadId == null || title == null || contexts.containsKey(threadId)) {
      continue;
    }
    contexts[threadId] = title;
  }
  return Map<String, String>.unmodifiable(contexts);
}

String? _dailyTopicTitle(String value) {
  final normalized = value.trim();
  final length = normalized.runes.length;
  return normalized.isEmpty || length > 500 ? null : normalized;
}

String _requireId(String value) {
  final normalized = _id(value);
  if (normalized == null) {
    throw ArgumentError('Desktop topics cache scope is invalid');
  }
  return normalized;
}

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$');
