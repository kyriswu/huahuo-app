import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_document_export_service.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_export_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KnowledgeExportDocument', () {
    test('snapshots display metadata without private attachment paths', () {
      final note = V3FeedItem(
        id: 'note-1',
        title: '中文知识',
        source: V3MaterialSource.mediaImport,
        createdAt: DateTime.utc(2026, 7, 18),
        updatedAt: DateTime.utc(2026, 7, 19, 8, 30),
        rawBody: '正文 file:///var/mobile/private.mov',
        summaryBody: '摘要',
        sproutTopic: '新的方向',
        topics: const <String>['AI'],
        mediaAttachments: const <V3MediaAttachment>[
          V3MediaAttachment(
            privateUri: 'app-private://media/secret',
            displayName: '访谈视频.mp4',
            mimeType: 'video/mp4',
            sizeBytes: 8,
            kind: V3MediaAttachmentKind.video,
            privatePath: '/var/mobile/Containers/Data/private.mov',
          ),
        ],
      );

      final document = KnowledgeExportDocument.fromNote(
        note,
        sourceLabel: '相册导入',
        effectiveTags: const <String>['AI', '访谈'],
      );

      expect(document.attachmentDisplayNames, const <String>['访谈视频.mp4']);
      expect(document.rawBody, contains('[已隐藏私有路径]'));
      expect(document.rawBody, isNot(contains('/var/mobile')));
      expect(document.sproutBody, '新的方向');
      expect(document.tags, const <String>['AI', '访谈']);
      expect(document.documentId, 'note-1');
      expect(document.revision, note.updatedAt.toUtc().microsecondsSinceEpoch);
    });

    test('share uses only an actual public URL and a bounded excerpt', () {
      final privateDocument = _document(
        publicUrl: 'app-private://knowledge/1',
        summaryBody: '摘要 /Users/run/private.txt',
      );
      final privatePayload = KnowledgeSharePayload.fromDocument(
        privateDocument,
      );
      expect(privatePayload.publicUrl, isNull);
      expect(privatePayload.text, isNot(contains('/Users/run')));
      expect(privatePayload.text, contains('[已隐藏私有路径]'));

      final publicPayload = KnowledgeSharePayload.fromDocument(
        _document(publicUrl: 'https://example.com/article?id=7'),
      );
      expect(publicPayload.publicUrl, 'https://example.com/article?id=7');
      expect(publicPayload.text, contains('https://example.com/article?id=7'));
    });

    test('omits unavailable derived stages from Markdown', () {
      final markdown = KnowledgeDocumentSerializer().serializeMarkdown(
        _document(rawBody: '已保存的原始转写', summaryBody: '', sproutBody: ''),
      );

      expect(markdown, contains('## 原始\n\n已保存的原始转写'));
      expect(markdown, isNot(contains('## 纲要')));
      expect(markdown, isNot(contains('## 深度洞察')));
      expect(markdown, isNot(contains('尚未生成')));
    });

    test('coalesces PDF renders by document revision and width', () async {
      var renders = 0;
      final firstRender = Completer<void>();
      final serializer = KnowledgeDocumentSerializer(
        fontLoader: () async => ByteData(1),
        pdfWorker: (document, _) async {
          renders += 1;
          if (document.revision == 1) await firstRender.future;
          return Uint8List.fromList(<int>[document.revision ?? 0]);
        },
      );
      final revisionOne = _document(documentId: 'note-1', revision: 1);

      final first = serializer.serializePdf(revisionOne);
      final duplicate = serializer.serializePdf(revisionOne);
      await Future<void>.delayed(Duration.zero);
      expect(renders, 1);
      firstRender.complete();
      expect(await first, Uint8List.fromList(<int>[1]));
      expect(await duplicate, Uint8List.fromList(<int>[1]));

      expect(
        await serializer.serializePdf(
          _document(documentId: 'note-1', revision: 2),
        ),
        Uint8List.fromList(<int>[2]),
      );
      expect(renders, 2);

      serializer.releaseMemory();
      expect(
        await serializer.serializePdf(revisionOne),
        Uint8List.fromList(<int>[1]),
      );
      expect(renders, 3);
    });
  });

  group('FileKnowledgeDocumentExportService', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('knowledge-export-test-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('writes real UTF-8 Markdown atomically behind an opaque ref', () async {
      final service = FileKnowledgeDocumentExportService(
        directoryResolver: () async => root,
        clock: () => DateTime.utc(2026, 7, 19, 9),
        idFactory: (_) => 'export-markdown-test',
      );

      final result = await service.prepare(
        _document(
          rawBody: '# 原始标题\n\n- 第一项\n- 第二项',
          summaryBody: '这是中文纲要。',
          sproutBody: '这是点火内容。',
        ),
        KnowledgeExportFormat.markdown,
      );

      expect(result.ok, isTrue);
      final prepared = result.value!;
      expect(
        prepared.opaqueExportRef,
        'app-private-export://knowledge/cache/export-markdown-test/knowledge.md',
      );
      expect(prepared.displayName, '知识测试.md');
      expect(prepared.mimeType, 'text/markdown');
      expect(prepared.opaqueExportRef, isNot(contains(root.path)));
      final file = File(
        '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
        'export-markdown-test/knowledge.md',
      );
      final bytes = await file.readAsBytes();
      final markdown = utf8.decode(bytes);
      expect(markdown, contains('# 知识测试'));
      expect(markdown, contains('> 来源：录音笔记 · 会议'));
      expect(markdown, contains('> 附件：会议录音.m4a'));
      expect(markdown, contains('## 原始'));
      expect(markdown, contains('## 纲要'));
      expect(markdown, contains('## 深度洞察'));
      expect(markdown.indexOf('## 原始'), lessThan(markdown.indexOf('## 纲要')));
      expect(markdown.indexOf('## 纲要'), lessThan(markdown.indexOf('## 深度洞察')));
      expect(await File('${file.path}.part').exists(), isFalse);
      expect(bytes, containsAllInOrder(utf8.encode('中文纲要')));

      await service.discard(prepared);
      expect(await file.parent.exists(), isFalse);
    });

    test(
      'disposed consumer rejects a blocked Markdown directory resolver',
      () async {
        final resolverEntered = Completer<void>();
        final releaseResolver = Completer<Directory>();
        var resolverCalls = 0;
        final orchestrator = TaskOrchestrator();
        addTearDown(orchestrator.dispose);
        final service = FileKnowledgeDocumentExportService(
          directoryResolver: () {
            resolverCalls += 1;
            resolverEntered.complete();
            return releaseResolver.future;
          },
          idFactory: (_) => 'export-markdown-disposed',
          taskOrchestrator: orchestrator,
        );

        final pending = service.prepare(
          _document(),
          KnowledgeExportFormat.markdown,
        );
        await resolverEntered.future;
        service.dispose();
        releaseResolver.complete(root);

        final result = await pending;
        expect(result.ok, isFalse);
        expect(result.error?.code, 'KNOWLEDGE_EXPORT_PREPARE_FAILED');
        expect(
          await Directory(
            '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
            'export-markdown-disposed',
          ).exists(),
          isFalse,
        );

        final afterDispose = await service.prepare(
          _document(),
          KnowledgeExportFormat.markdown,
        );
        expect(afterDispose.ok, isFalse);
        expect(resolverCalls, 1);
      },
    );

    test(
      'stages a downloaded digital-twin ZIP behind the same opaque ref',
      () async {
        final orchestrator = TaskOrchestrator();
        addTearDown(orchestrator.dispose);
        final service = FileKnowledgeDocumentExportService(
          directoryResolver: () async => root,
          clock: () => DateTime.utc(2026, 8, 29),
          idFactory: (_) => 'export-digital-twin-test',
          taskOrchestrator: orchestrator,
        );
        final bytes = Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04]);

        final result = await service.prepareArchive(
          title: 'digital-twin-v1',
          bytes: bytes,
        );

        expect(result.ok, isTrue);
        expect(result.value?.mimeType, 'application/zip');
        expect(result.value?.displayName, 'digital-twin-v1.zip');
        final file = File(
          '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
          'export-digital-twin-test/digital-twin-v1.zip',
        );
        expect(await file.readAsBytes(), bytes);
        expect(await File('${file.path}.part').exists(), isFalse);
        final task = orchestrator.snapshot.projections.singleWhere(
          (projection) => projection.spec.owner == 'knowledge-zip-export',
        );
        expect(task.spec.resources, <TaskResource>{TaskResource.media});
        expect(task.spec.key, startsWith('knowledge:zip-export:'));
        expect(task.spec.key, isNot(contains('digital-twin-v1')));
      },
    );

    test(
      'builds a nonempty Chinese multipage PDF from rich Markdown',
      () async {
        final orchestrator = TaskOrchestrator();
        addTearDown(orchestrator.dispose);
        final service = FileKnowledgeDocumentExportService(
          directoryResolver: () async => root,
          clock: () => DateTime.utc(2026, 7, 19, 9),
          idFactory: (_) => 'export-pdf-test',
          taskOrchestrator: orchestrator,
        );
        final longBody = List<String>.generate(
          180,
          (index) => index % 4 == 0
              ? '## 小节 $index\n- 列表项目 $index\n> 引用内容 $index'
              : '第 $index 段中文内容，用于验证自动分页。',
        ).join('\n\n');

        final diagnostics = <String>[];
        final result = await runZoned(
          () => service.prepare(
            _document(
              rawBody:
                  '$longBody\n\n'
                  '##共享标题修复\n**粗体**、*斜体*、~~删除~~、<u>下划线</u>\n'
                  '- [x] 完成\n[参考](https://example.com)\n'
                  '```markdown\n| 原样 | 代码 |\n| --- | --- |\n| A | B |\n```\n'
                  '| 实际 | 表格 |\n| --- | --- |\n| **内容** | 数据 |',
            ),
            KnowledgeExportFormat.pdf,
          ),
          zoneSpecification: ZoneSpecification(
            print: (_, __, ___, line) => diagnostics.add(line),
          ),
        );

        expect(result.ok, isTrue, reason: result.error?.code);
        expect(
          diagnostics.where((line) => line.contains('Unable to find a font')),
          isEmpty,
        );
        final prepared = result.value!;
        expect(prepared.mimeType, 'application/pdf');
        expect(prepared.sizeBytes, greaterThan(10000));
        final file = File(
          '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
          'export-pdf-test/knowledge.pdf',
        );
        final bytes = await file.readAsBytes();
        expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
        expect(await File('${file.path}.part').exists(), isFalse);
        final task = orchestrator.snapshot.projections.singleWhere(
          (projection) => projection.spec.owner == 'knowledge-pdf-export',
        );
        expect(task.spec.resources, <TaskResource>{
          TaskResource.cpu,
          TaskResource.media,
        });
        expect(task.spec.key, startsWith('knowledge:pdf-export:'));
        expect(task.spec.key, isNot(contains('知识测试')));
      },
    );

    test('removes failed PDF staging without exposing a path', () async {
      final serializer = KnowledgeDocumentSerializer(
        fontLoader: () async => throw StateError('font unavailable'),
      );
      final service = FileKnowledgeDocumentExportService(
        serializer: serializer,
        directoryResolver: () async => root,
        idFactory: (_) => 'export-failure-test',
      );

      final result = await service.prepare(
        _document(),
        KnowledgeExportFormat.pdf,
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'KNOWLEDGE_EXPORT_PREPARE_FAILED');
      expect(result.error?.message, isNot(contains(root.path)));
      expect(
        await Directory(
          '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
          'export-failure-test',
        ).exists(),
        isFalse,
      );
    });

    test(
      'disposed consumer drops a late PDF worker result and cache',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final serializer = KnowledgeDocumentSerializer(
          fontLoader: () async => ByteData(1),
          pdfWorker: (document, fontBytes) async {
            started.complete();
            await release.future;
            return Uint8List.fromList(<int>[1, 2, 3]);
          },
        );
        final orchestrator = TaskOrchestrator();
        addTearDown(orchestrator.dispose);
        final service = FileKnowledgeDocumentExportService(
          serializer: serializer,
          directoryResolver: () async => root,
          idFactory: (_) => 'export-disposed-test',
          taskOrchestrator: orchestrator,
        );

        final resultFuture = service.prepare(
          _document(documentId: 'note-disposed', revision: 4),
          KnowledgeExportFormat.pdf,
        );
        await started.future;
        expect(service.cachedPdfRenderCount, 1);
        service.dispose();
        expect(service.cachedPdfRenderCount, 0);
        release.complete();

        final result = await resultFuture;
        expect(result.ok, isFalse);
        expect(service.cachedPdfRenderCount, 0);
        expect(
          await Directory(
            '${root.path}/HuahuoAI/TemporaryTransfers/knowledge/cache/'
            'export-disposed-test',
          ).exists(),
          isFalse,
        );
        final task = orchestrator.snapshot.projections.singleWhere(
          (projection) => projection.spec.owner == 'knowledge-pdf-export',
        );
        expect(task.state, isA<AppTaskCancelled>());
      },
    );
  });
}

KnowledgeExportDocument _document({
  String rawBody = '原始正文',
  String summaryBody = '摘要正文',
  String sproutBody = '点火正文',
  String? publicUrl,
  String? documentId,
  int? revision,
}) {
  return KnowledgeExportDocument(
    title: '知识测试',
    sourceLabel: '录音笔记 · 会议',
    updatedAt: DateTime.utc(2026, 7, 19, 8, 30),
    tags: const <String>['产品', 'AI'],
    attachmentDisplayNames: const <String>['会议录音.m4a'],
    rawBody: rawBody,
    summaryBody: summaryBody,
    sproutBody: sproutBody,
    publicUrl: publicUrl,
    documentId: documentId,
    revision: revision,
  );
}
