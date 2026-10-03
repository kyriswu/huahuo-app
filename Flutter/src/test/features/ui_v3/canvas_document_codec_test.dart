import 'dart:convert';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_document_codec.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_image_embed_data.dart';

void main() {
  late CanvasDocumentCodec codec;

  setUp(() {
    codec = CanvasDocumentCodec();
  });

  test(
    'canonical JSON keeps supported attributes and one terminal newline',
    () {
      final delta = Delta()
        ..insert('标题', <String, dynamic>{
          'bold': true,
          'color': '#FF3366',
          'unsupported': 'discarded',
        })
        ..insert('\n', <String, dynamic>{'header': 2, 'align': 'center'})
        ..insert('正文');

      expect(jsonDecode(codec.encodeDeltaJson(delta)), <Object?>[
        <String, Object?>{
          'insert': '标题',
          'attributes': <String, Object?>{'bold': true, 'color': '#ff3366'},
        },
        <String, Object?>{
          'insert': '\n',
          'attributes': <String, Object?>{'header': 2, 'align': 'center'},
        },
        <String, Object?>{'insert': '正文\n'},
      ]);
    },
  );

  test(
    'standard and extended inline formatting survives Markdown round trip',
    () {
      final delta = Delta()
        ..insert('重点', <String, dynamic>{
          'bold': true,
          'italic': true,
          'underline': true,
          'strike': true,
          'color': '#e5484d',
          'background': '#fff1a8',
        })
        ..insert('与')
        ..insert('代码', <String, dynamic>{'code': true})
        ..insert('和')
        ..insert('链接', <String, dynamic>{'link': 'https://example.com/note'})
        ..insert('\n');

      final markdown = codec.deltaToMarkdown(delta);
      final restored = codec.markdownToDelta(markdown);

      expect(markdown, contains('<u>'));
      expect(markdown, contains('data-hh-fg="#e5484d"'));
      expect(markdown, contains('data-hh-bg="#fff1a8"'));
      expect(markdown, contains('**'));
      expect(markdown, contains('~~'));
      expect(markdown, contains('`代码`'));
      expect(markdown, contains('[链接](https://example.com/note)'));
      expect(markdown, isNot(contains('data-hh-bold')));
      expect(markdown, isNot(contains('data-hh-strike')));
      expect(markdown, isNot(contains('data-hh-code')));
      expect(markdown, isNot(contains('data-hh-link')));
      expect(codec.encodeDeltaJson(restored), codec.encodeDeltaJson(delta));
    },
  );

  test('accepts ordinary Markdown and restricted color HTML', () {
    final restored = codec.markdownToDelta(
      '**粗体**和<u>下划线</u>及'
      '<span data-hh-fg="#3366ff">蓝色</span>',
    );

    expect(
      restored.toJson(),
      containsAll(<Object?>[
        <String, Object?>{
          'insert': '粗体',
          'attributes': <String, Object?>{'bold': true},
        },
        <String, Object?>{
          'insert': '下划线',
          'attributes': <String, Object?>{'underline': true},
        },
        <String, Object?>{
          'insert': '蓝色',
          'attributes': <String, Object?>{'color': '#3366ff'},
        },
      ]),
    );
    expect(
      () => codec.markdownToDelta('<span data-hh-fg="red">不安全颜色</span>'),
      throwsFormatException,
    );
  });

  test('block formats, alignment, divider, and check lists are projected', () {
    final delta = Delta()
      ..insert('标题')
      ..insert('\n', <String, dynamic>{'header': 1, 'align': 'center'})
      ..insert('引用')
      ..insert('\n', <String, dynamic>{'blockquote': true})
      ..insert('第一项')
      ..insert('\n', <String, dynamic>{'list': 'ordered'})
      ..insert('已完成')
      ..insert('\n', <String, dynamic>{'list': 'checked'})
      ..insert('待完成')
      ..insert('\n', <String, dynamic>{'list': 'unchecked'})
      ..insert('print(1)')
      ..insert('\n', <String, dynamic>{'code-block': true})
      ..insert(const <String, String>{'divider': 'hr'})
      ..insert('\n');

    final markdown = codec.deltaToMarkdown(delta);
    final restored = codec.markdownToDelta(markdown);
    final restoredJson = codec.encodeDeltaJson(restored);

    expect(markdown, contains('<div align="center">\n# 标题\n</div>'));
    expect(markdown, contains('> 引用'));
    expect(markdown, contains('1. 第一项'));
    expect(markdown, contains('- [x] 已完成'));
    expect(markdown, contains('- [ ] 待完成'));
    expect(markdown, contains('```'));
    expect(markdown, contains('---'));
    expect(restoredJson, contains('"header":1'));
    expect(restoredJson, contains('"align":"center"'));
    expect(restoredJson, contains('"blockquote":true'));
    expect(restoredJson, contains('"list":"checked"'));
    expect(restoredJson, contains('"code-block":true'));
    expect(restoredJson, contains('"canvas-divider":{"version":1}'));
    expect(
      codec
          .normalizeDelta(
            Delta()..insert(CanvasDocumentCodec.canvasDividerDeltaInsert),
          )
          .first
          .data,
      CanvasDocumentCodec.canvasDividerDeltaInsert,
    );
  });

  test('private image embed round trips without a filesystem path', () {
    final image = CanvasImageEmbedData(
      resourceId: 'canvas-a1b2c3.webp',
      alt: '会议白板',
      widthRatio: .65,
      aspectRatio: 4 / 3,
    );
    final delta = Delta()
      ..insert(image.toDeltaInsert())
      ..insert('\n');

    final markdown = codec.deltaToMarkdown(delta);
    final restored = codec.markdownToDelta(markdown);

    expect(
      markdown,
      contains(
        '![会议白板](app-private-canvas-image://canvas-a1b2c3.webp?'
        'width=0.65&aspect=1.3333333333333333)',
      ),
    );
    expect(markdown, isNot(contains('/Users/')));
    expect(CanvasImageEmbedData.fromDeltaInsert(restored.first.data), image);
  });

  test(
    'image payload rejects paths, URLs, invalid sizing, and bad versions',
    () {
      CanvasImageEmbedData create({
        String resourceId = 'canvas-safe.png',
        double widthRatio = .5,
        double aspectRatio = 1,
        int version = 1,
      }) {
        return CanvasImageEmbedData(
          version: version,
          resourceId: resourceId,
          alt: '图片',
          widthRatio: widthRatio,
          aspectRatio: aspectRatio,
        );
      }

      expect(
        () => create(resourceId: '/private/image.png'),
        throwsArgumentError,
      );
      expect(
        () => create(resourceId: 'https://example.com/image.png'),
        throwsArgumentError,
      );
      expect(() => create(widthRatio: .2), throwsArgumentError);
      expect(() => create(aspectRatio: double.nan), throwsArgumentError);
      expect(() => create(version: 2), throwsArgumentError);
      expect(
        () => CanvasImageEmbedData.fromJson(const <String, Object?>{
          'version': 1.5,
          'resourceId': 'canvas-safe.png',
          'alt': '图片',
          'widthRatio': .5,
          'aspectRatio': 1,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'decoder rejects change deltas, public image embeds, and malformed JSON',
    () {
      expect(
        () => codec.normalizeDelta(Delta()..retain(1)),
        throwsFormatException,
      );
      expect(
        () => codec.normalizeDelta(
          Delta()..insert(<String, String>{'image': '/private/image.png'}),
        ),
        throwsFormatException,
      );
      expect(() => codec.decodeDeltaJson('{}'), throwsFormatException);
      expect(
        () => codec.decodeDeltaJson('[{"delete":1}]'),
        throwsFormatException,
      );
      expect(
        () => codec.markdownToDelta(
          '![公网图片](https://example.com/not-private.png)',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'empty Markdown and documents use the Quill terminal newline invariant',
    () {
      expect(
        codec.encodeDeltaJson(codec.markdownToDelta('')),
        '[{"insert":"\\n"}]',
      );
      expect(
        codec.encodeDocumentJson(codec.documentFromMarkdown('')),
        '[{"insert":"\\n"}]',
      );
      expect(codec.documentToMarkdown(codec.documentFromMarkdown('')), '');
    },
  );
}
