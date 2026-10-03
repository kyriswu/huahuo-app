import 'dart:convert';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  test('normalizes Mobile attributes, private images, and Markdown', () {
    final image = HuahuoDocumentImageData(
      resourceId: 'canvas-shared.png',
      alt: '共享图片',
      widthRatio: .5,
      aspectRatio: 4 / 3,
    );
    final delta = Delta()
      ..insert('标题', <String, Object?>{
        'bold': true,
        'color': '#FF3366',
        'unsupported': true,
      })
      ..insert('\n', <String, Object?>{'header': 2, 'align': 'center'})
      ..insert(image.toDeltaInsert())
      ..insert('\n');

    final encoded = HuahuoDocumentCodec.encodeDelta(delta);
    final markdown = HuahuoDocumentCodec.deltaToMarkdown(
      HuahuoDocumentCodec.decode(encoded),
    );
    final restored = HuahuoDocumentCodec.markdownToDelta(markdown);

    expect(encoded, isNot(contains('unsupported')));
    expect(encoded, contains('#ff3366'));
    expect(markdown, contains('app-private-canvas-image://canvas-shared.png'));
    expect(markdown, isNot(contains('/Users/')));
    expect(
      HuahuoDocumentCodec.encodeDelta(restored),
      HuahuoDocumentCodec.encodeDelta(HuahuoDocumentCodec.decode(encoded)),
    );
    expect(
      HuahuoDocumentCodec.normalize(
        Delta()..insert(const <String, String>{'divider': 'hr'}),
      ).first.data,
      HuahuoDocumentCodec.canvasDividerDeltaInsert,
    );
  });

  test('reads v2 and writes a lossless v3 cross-device snapshot', () {
    final now = DateTime.utc(2026, 7, 31, 8);
    final v2 = <String, Object?>{
      'formatVersion': 2,
      'id': 'note-v2',
      'title': '旧文档',
      'delta': <Object?>[
        <String, Object?>{'insert': '正文\n'},
      ],
      'revision': 2,
      'createdAt': now.toIso8601String(),
      'modifiedAt': now.toIso8601String(),
      'note': <String, Object?>{'summaryMarkdown': '# 摘要'},
    };
    final migrated = HuahuoDocumentSnapshot.fromJson(v2);
    final enriched = HuahuoDocumentSnapshot(
      id: migrated.id,
      title: migrated.title,
      deltaJson: migrated.deltaJson,
      markdownProjection: '# 正文\n',
      linkedMaterials: <HuahuoLinkedMaterialRef>[
        HuahuoLinkedMaterialRef(
          id: 'recording-1',
          source: 'meeting',
          title: '会议录音',
          summary: '讨论摘要',
        ),
      ],
      sourceTopicId: 'topic-1',
      sourceTopicTitle: '选题',
      revision: migrated.revision,
      createdAt: migrated.createdAt,
      modifiedAt: migrated.modifiedAt,
      summaryMarkdown: migrated.summaryMarkdown,
    );

    final restored = HuahuoDocumentSnapshot.fromJson(enriched.toJson());

    expect(restored.markdownProjection, '# 正文\n');
    expect(restored.linkedMaterials.single.source, 'meeting');
    expect(restored.linkedMaterials.single.summary, '讨论摘要');
    expect(restored.sourceTopicId, 'topic-1');
    expect(restored.sourceTopicTitle, '选题');
    expect(restored.summaryMarkdown, '# 摘要');
    expect(restored.toJson()['formatVersion'], 3);
    expect(jsonDecode(restored.deltaJson), isA<List<Object?>>());
  });

  test('preserves validated Desktop image embeds and rejects unsafe ones', () {
    const local = 'huahuo-media://asset/abcdefghijklmnop';
    final delta = Delta()
      ..insert(<String, Object>{'image': local})
      ..insert(<String, Object>{'image': 'https://cdn.huahuo.ai/cover.png'})
      ..insert('\n');

    final encoded = HuahuoDocumentCodec.encodeDelta(delta);

    expect(encoded, contains(local));
    expect(encoded, contains('https://cdn.huahuo.ai/cover.png'));
    expect(
      () => HuahuoDocumentCodec.normalize(
        Delta()..insert(<String, Object>{'image': 'file:///Users/demo/a.png'}),
      ),
      throwsFormatException,
    );
    expect(
      () => HuahuoDocumentCodec.normalize(
        Delta()..insert(<String, Object>{'video': 'https://example.test/a'}),
      ),
      throwsFormatException,
    );
  });

  test('rejects unsupported future snapshots and unsafe image identifiers', () {
    final now = DateTime.utc(2026, 7, 31, 8).toIso8601String();
    expect(
      () => HuahuoDocumentSnapshot.fromJson(<String, Object?>{
        'formatVersion': 4,
        'id': 'future',
        'title': 'future',
        'delta': <Object?>[
          <String, Object?>{'insert': '\n'},
        ],
        'revision': 1,
        'createdAt': now,
        'modifiedAt': now,
      }),
      throwsFormatException,
    );
    expect(
      () => HuahuoDocumentImageData(
        resourceId: '/Users/demo/image.png',
        alt: '图片',
        widthRatio: .5,
        aspectRatio: 1,
      ),
      throwsArgumentError,
    );
  });
}
