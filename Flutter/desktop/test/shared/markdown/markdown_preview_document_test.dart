import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/shared/markdown/markdown_preview.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

void main() {
  const compiler = MarkdownPreviewDocumentCompiler();

  test('desktop uses the Assistant parser without an HTML representation', () {
    final result = compiler.compile(
      source: const MarkdownPreviewSource(
        title: '文稿',
        markdown: '##标题\n\n**正文**\n\n| 名称 | 内容 |\n| --- | --- |\n| A | B |',
      ),
    );
    expect(result.headings.single.title, '标题');
    expect(
      result.document.blocks.where(
        (block) => block.kind == HuahuoMarkdownBlockKind.table,
      ),
      hasLength(1),
    );
    expect(result.document.blocks.first.sourceLine, 0);
  });

  test('preview retains source, metadata, and heading limits', () {
    for (final source in [
      MarkdownPreviewSource(
        title: '文稿',
        markdown:
            'x' *
            (MarkdownPreviewDocumentCompiler.maximumDocumentCharacters + 1),
      ),
      MarkdownPreviewSource(
        title:
            'x' * (MarkdownPreviewDocumentCompiler.maximumTitleCharacters + 1),
        markdown: '正文',
      ),
      MarkdownPreviewSource(
        title: '文稿',
        markdown:
            '# 标题\n' *
            (MarkdownPreviewDocumentCompiler.maximumDocumentHeadings + 1),
      ),
    ]) {
      expect(
        () => compiler.compile(source: source),
        throwsA(isA<MarkdownPreviewSafetyException>()),
      );
    }
  });

  test('preview media requires the original explicit safety policy', () {
    expect(
      MarkdownPreviewDocumentCompiler.isSafeImageSource(
        'file:///private/image.png',
        true,
      ),
      isFalse,
    );
    expect(
      MarkdownPreviewDocumentCompiler.isSafeImageSource(
        'https://example.com/image.png',
        false,
      ),
      isFalse,
    );
    expect(
      MarkdownPreviewDocumentCompiler.isSafeImageSource(
        'https://example.com/image.png',
        true,
      ),
      isTrue,
    );
    expect(
      MarkdownPreviewDocumentCompiler.isSafeImageSource(
        'huahuo-media://asset/AbcdefghijklmnopQRSTUVWX',
        false,
      ),
      isTrue,
    );
    expect(
      MarkdownPreviewDocumentCompiler.isSafeImageSource(
        'huahuo-media://asset/../../file',
        false,
      ),
      isFalse,
    );
  });
}
