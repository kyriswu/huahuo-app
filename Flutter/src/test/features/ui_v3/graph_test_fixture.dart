import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

const graphTestPrimaryNoteId = 'demo-laozhou-001';
const graphTestSearchNoteId = 'graph-sleep-note';
const graphTestAudioNoteId = 'graph-recording-card-note';
const graphTestSubscriptionId = 'graph-subscription-original';
const graphTestHotspotId = 'graph-current-hotspot';

List<V3FeedItem> buildGraphTestNotes({int count = 50}) {
  assert(count >= 8);
  const sources = <V3MaterialSource>[
    V3MaterialSource.note,
    V3MaterialSource.recordingCard,
    V3MaterialSource.monologue,
    V3MaterialSource.documentImport,
    V3MaterialSource.link,
    V3MaterialSource.meeting,
  ];
  return <V3FeedItem>[
    for (var index = 0; index < count; index++)
      () {
        final number = index + 1;
        final id = switch (index) {
          0 => graphTestPrimaryNoteId,
          1 => 'demo-laozhou-012',
          2 => graphTestSearchNoteId,
          6 => graphTestAudioNoteId,
          _ when index == count - 2 => graphTestSubscriptionId,
          _ when index == count - 1 => graphTestHotspotId,
          _ => 'graph-test-${number.toString().padLeft(3, '0')}',
        };
        final source = switch (index) {
          0 || 1 || 2 => V3MaterialSource.note,
          6 => V3MaterialSource.recordingCard,
          _ when index == count - 2 => V3MaterialSource.subscription,
          _ when index == count - 1 => V3MaterialSource.hotspot,
          _ => sources[index % sources.length],
        };
        final title = switch (id) {
          graphTestPrimaryNoteId => '第一次被客户赶出办公室',
          'demo-laozhou-012' => '很多事情不是没有答案，而是答案有代价',
          graphTestSearchNoteId => '睡眠、精力与重大选择',
          graphTestAudioNoteId => '录音卡里的中年复盘',
          graphTestSubscriptionId => '成年人选择观察周刊',
          graphTestHotspotId => '成年人开始重新讨论生活的代价',
          _ => '老周图谱测试笔记 $number',
        };
        return V3FeedItem(
          id: id,
          title: title,
          source: source,
          ownership: switch (source) {
            V3MaterialSource.subscription => V3NoteOwnership.subscribed,
            V3MaterialSource.hotspot => V3NoteOwnership.hotspot,
            _ => V3NoteOwnership.mine,
          },
          createdAt: DateTime.utc(2026, 7, 29).subtract(Duration(hours: index)),
          rawBody: '$title。记录事实、情绪、选择与代价，并给出一个可以验证的小行动。',
          summaryBody: '纲要\n\n$title 的判断过程与适用边界。',
          topics: <String>[
            if (id == graphTestSearchNoteId) '睡眠',
            if (id == graphTestAudioNoteId) '录音卡',
            '成对主题 ${index ~/ 2}',
            '节点主题 $index',
          ],
          contentLineId: 'graph-line-${index ~/ 2}',
          contentLineName: '图谱内容线 ${index ~/ 2}',
        );
      }(),
  ];
}
