import 'package:flutter_quill/flutter_quill.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

List<HuahuoDocumentSnapshot> buildDesktopSeedDocuments() {
  final now = DateTime.now().toUtc();
  return <HuahuoDocumentSnapshot>[
    _seedDocument(id: 'welcome-draft', title: '未命名文稿', body: '', now: now),
    _seedDocument(
      id: 'city-running-script',
      title: '短视频脚本：城市夜跑',
      body: '夜色落下以后，城市换了一种呼吸。\n\n从第一个路口开始，把脚步、灯光和街道的声音写进镜头。',
      summaryMarkdown:
          '## 开场场景\n\n夜跑者进入街道，城市从白天的节奏切换到夜晚。\n\n## 叙事推进\n\n用脚步、灯光和环境声建立镜头感。',
      sproutMarkdown: '# 发芽洞见\n\n把“城市的第二种呼吸”作为贯穿意象，结尾回到跑者与城市重新建立连接的时刻。',
      now: now.subtract(const Duration(hours: 3)),
    ),
    _seedDocument(
      id: 'interview-outline',
      title: '产品访谈提纲',
      body: '先聊最近一次真实使用，再追问当时的目标、阻碍和替代方案。',
      summaryMarkdown:
          '## 访谈路径\n\n1. 最近一次真实使用\n2. 当时的目标与阻碍\n3. 现有替代方案\n4. 期待的改变',
      now: now.subtract(const Duration(days: 1)),
    ),
  ];
}

HuahuoDocumentSnapshot _seedDocument({
  required String id,
  required String title,
  required String body,
  required DateTime now,
  String? summaryMarkdown,
  String? sproutMarkdown,
}) {
  final document = Document()..insert(0, body);
  return HuahuoDocumentSnapshot(
    id: id,
    title: title,
    deltaJson: HuahuoDocumentCodec.encode(document),
    revision: 0,
    createdAt: now,
    modifiedAt: now,
    summaryMarkdown: summaryMarkdown,
    sproutMarkdown: sproutMarkdown,
  );
}
