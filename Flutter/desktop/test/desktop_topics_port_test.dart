import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/topics/data/desktop_topics_adapters.dart'
    as legacy_topics_adapter;
import 'package:huahuo_desktop/features/topics/data/desktop_topics_cache.dart';

void main() {
  test(
    'legacy data adapter path exports the unavailable topics port',
    () async {
      const port = legacy_topics_adapter.UnavailableDesktopTopicsPort();

      final result = await port.listDailyTopics('workspace_1');

      expect(result.isUnavailable, isTrue);
      expect(result.code, 'DAILY_TOPIC_SERVICE_UNAVAILABLE');
    },
  );

  test('desktop topics cache is isolated by user and Workspace', () async {
    final directory = await Directory.systemTemp.createTemp('desktop-topics-');
    addTearDown(() => directory.delete(recursive: true));
    final cache = LocalDesktopTopicsCache(
      supportDirectory: () async => directory,
    );
    final recommendation = DailyTopicRecommendation.fromJson(<String, Object?>{
      'recommendationId': 'daily_1',
      'workspaceId': 'workspace_1',
      'businessDate': '2026-08-14',
      'recommendationKind': 'daily_topic_report',
      'status': 'ready',
      'title': '今日选题',
      'summaryMarkdown': '## 摘要',
      'etag': '"daily-1"',
      'topics': <Object?>[
        <String, Object?>{
          'topicId': 'topic_1',
          'title': '一个方向',
          'briefMarkdown': '简要说明',
          'sourceRefs': <Object?>[
            <String, Object?>{
              'kind': 'daily_hotspot',
              'hotspotId': 'hotspot_1',
            },
          ],
        },
      ],
    });

    await cache.save(
      userId: 'user_1',
      workspaceId: 'workspace_1',
      snapshot: DesktopTopicsCacheSnapshot(
        dailyRecommendation: recommendation,
        dailyExpiresAt: DateTime.utc(2026, 8, 14, 1),
        dailyTopicContextsByThread: const <String, String>{
          'thread_1': '第一条公开选题',
        },
        topicCollisionRun: const TopicCollisionRun(
          topicCollisionRunId: 'collision_1',
          status: 'running',
          selectedNoteCount: 4,
          sources: <TopicCollisionSource>[
            TopicCollisionSource(inputRef: 'note-01', title: '来源一'),
            TopicCollisionSource(inputRef: 'note-02', title: '来源二'),
            TopicCollisionSource(inputRef: 'note-03', title: '来源三'),
            TopicCollisionSource(inputRef: 'note-04', title: '来源四'),
          ],
        ),
        topicCollisionCreatedAt: DateTime.utc(2026, 8, 14),
      ),
    );

    final restored = await cache.load(
      userId: 'user_1',
      workspaceId: 'workspace_1',
    );
    final otherUser = await cache.load(
      userId: 'user_2',
      workspaceId: 'workspace_1',
    );

    expect(restored.dailyRecommendation?.recommendationId, 'daily_1');
    expect(restored.dailyTopicContextsByThread['thread_1'], '第一条公开选题');
    expect(restored.topicCollisionRunId, 'collision_1');
    expect(restored.topicCollisionRun?.status, 'running');
    expect(
      restored.topicCollisionRun?.sources.map((source) => source.title),
      orderedEquals(<String?>['来源一', '来源二', '来源三', '来源四']),
    );
    expect(otherUser.dailyRecommendation, isNull);
    expect(otherUser.dailyTopicContextsByThread, isEmpty);
    expect(otherUser.topicCollisionRunId, isNull);
  });

  test(
    'legacy ID-only collision cache remains recoverable until refreshed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-topics-legacy-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const userId = 'legacy_user';
      const workspaceId = 'legacy_workspace';
      final scope = base64Url
          .encode(utf8.encode('$userId|$workspaceId'))
          .replaceAll('=', '');
      final file = File(
        '${directory.path}${Platform.pathSeparator}topics-$scope.json',
      );
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'topicCollisionRunId': 'collision_legacy',
          'topicCollisionCreatedAt': '2026-08-14T00:00:00Z',
        }),
      );
      final cache = LocalDesktopTopicsCache(
        supportDirectory: () async => directory,
      );

      final restored = await cache.load(
        userId: userId,
        workspaceId: workspaceId,
      );

      expect(restored.topicCollisionRunId, 'collision_legacy');
      expect(restored.topicCollisionRun?.sources, isEmpty);

      await cache.save(
        userId: userId,
        workspaceId: workspaceId,
        snapshot: restored,
      );
      final persisted =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(persisted['schemaVersion'], 2);
      expect(persisted['topicCollisionRunId'], 'collision_legacy');
    },
  );
}
