import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/tasking/task_orchestrator.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import '../domain/knowledge_export_models.dart';

typedef KnowledgeExportDirectoryResolver = Future<Directory> Function();
typedef KnowledgeExportClock = DateTime Function();
typedef KnowledgeExportIdFactory = String Function(DateTime now);
typedef KnowledgeExportFontLoader = Future<ByteData> Function();
typedef KnowledgePdfWorker =
    Future<Uint8List> Function(
      KnowledgeExportDocument document,
      Uint8List fontBytes,
    );

abstract interface class KnowledgeDocumentExportService {
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepare(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
  );

  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepareArchive({
    required String title,
    required Uint8List bytes,
  });

  Future<void> discard(PreparedKnowledgeExport export);
}

final class KnowledgeDocumentSerializer {
  KnowledgeDocumentSerializer({
    KnowledgeExportFontLoader? fontLoader,
    KnowledgePdfWorker? pdfWorker,
    this.maxCachedPdfBytes = 24 * 1024 * 1024,
  }) : _fontLoader = fontLoader ?? _loadBundledFont,
       _pdfWorker = pdfWorker ?? _runKnowledgePdfWorker;

  final KnowledgeExportFontLoader _fontLoader;
  final KnowledgePdfWorker _pdfWorker;
  final int maxCachedPdfBytes;
  final LinkedHashMap<_DocumentRenderKey, Future<Uint8List>> _pdfRenders =
      LinkedHashMap<_DocumentRenderKey, Future<Uint8List>>();
  final Map<_DocumentRenderKey, int> _pdfRenderSizes =
      <_DocumentRenderKey, int>{};
  int _cachedPdfBytes = 0;
  int _cacheGeneration = 0;

  String serializeMarkdown(KnowledgeExportDocument document) {
    final buffer = StringBuffer()
      ..writeln('# ${document.title}')
      ..writeln()
      ..writeln('> 来源：${document.sourceLabel}')
      ..writeln('> 更新时间：${_formatDate(document.updatedAt)}');
    if (document.tags.isNotEmpty) {
      buffer.writeln('> 标签：${document.tags.join('、')}');
    }
    if (document.attachmentDisplayNames.isNotEmpty) {
      buffer.writeln('> 附件：${document.attachmentDisplayNames.join('、')}');
    }
    _appendMarkdownSection(
      buffer,
      '原始',
      document.rawBody,
      emptyLabel: '暂无原始内容',
    );
    if (document.summaryBody.trim().isNotEmpty) {
      _appendMarkdownSection(
        buffer,
        '纲要',
        document.summaryBody,
        emptyLabel: '尚未生成',
      );
    }
    if (document.sproutBody.trim().isNotEmpty) {
      _appendMarkdownSection(
        buffer,
        '深度洞察',
        document.sproutBody,
        emptyLabel: '尚未生成',
      );
    }
    return '${buffer.toString().trimRight()}\n';
  }

  Future<Uint8List> serializePdf(
    KnowledgeExportDocument document, {
    AppTaskCancellationToken? cancellationToken,
  }) {
    final key = _DocumentRenderKey.fromDocument(document);
    if (key == null) return _renderPdf(document, cancellationToken);
    final cached = _pdfRenders.remove(key);
    if (cached != null) {
      _pdfRenders[key] = cached;
      return cached;
    }
    final generation = _cacheGeneration;
    final rendered = _renderPdf(document, cancellationToken);
    _pdfRenders[key] = rendered;
    _trimPdfCache();
    rendered.then<void>(
      (bytes) {
        if (generation != _cacheGeneration ||
            !identical(_pdfRenders[key], rendered)) {
          return;
        }
        final previousSize = _pdfRenderSizes[key] ?? 0;
        _pdfRenderSizes[key] = bytes.lengthInBytes;
        _cachedPdfBytes += bytes.lengthInBytes - previousSize;
        _trimPdfCache();
      },
      onError: (Object _, StackTrace __) {
        if (identical(_pdfRenders[key], rendered)) _removePdfRender(key);
      },
    );
    return rendered;
  }

  Future<Uint8List> _renderPdf(
    KnowledgeExportDocument document,
    AppTaskCancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    final loaded = await _fontLoader();
    cancellationToken?.throwIfCancelled();
    final bytes = loaded.buffer.asUint8List(
      loaded.offsetInBytes,
      loaded.lengthInBytes,
    );
    final rendered = await _pdfWorker(document, bytes);
    cancellationToken?.throwIfCancelled();
    return rendered;
  }

  @visibleForTesting
  int get cachedPdfRenderCount => _pdfRenders.length;

  void releaseMemory() {
    _cacheGeneration += 1;
    _pdfRenders.clear();
    _pdfRenderSizes.clear();
    _cachedPdfBytes = 0;
  }

  void _trimPdfCache() {
    while (_pdfRenders.length > 3) {
      _removePdfRender(_pdfRenders.keys.first);
    }
    while (_cachedPdfBytes > maxCachedPdfBytes) {
      _DocumentRenderKey? oldestCompleted;
      for (final key in _pdfRenders.keys) {
        if (_pdfRenderSizes.containsKey(key)) {
          oldestCompleted = key;
          break;
        }
      }
      if (oldestCompleted == null) break;
      _removePdfRender(oldestCompleted);
    }
  }

  void _removePdfRender(_DocumentRenderKey key) {
    _pdfRenders.remove(key);
    _cachedPdfBytes -= _pdfRenderSizes.remove(key) ?? 0;
  }

  static Future<ByteData> _loadBundledFont() {
    return rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf');
  }
}

Future<Uint8List> _runKnowledgePdfWorker(
  KnowledgeExportDocument document,
  Uint8List fontBytes,
) async {
  final input = TransferableTypedData.fromList(<Uint8List>[fontBytes]);
  final output = await Isolate.run(() async {
    final rendered = await _serializeKnowledgePdf(
      document,
      input.materialize().asUint8List(),
    );
    return TransferableTypedData.fromList(<Uint8List>[rendered]);
  });
  return output.materialize().asUint8List();
}

Future<Uint8List> _serializeKnowledgePdf(
  KnowledgeExportDocument document,
  Uint8List fontBytes,
) async {
  final font = pw.Font.ttf(ByteData.sublistView(fontBytes));
  final pdf = pw.Document(
    title: document.title,
    author: '无限花火',
    creator: '无限花火',
  );
  final theme = pw.ThemeData.withFont(
    base: font,
    bold: font,
    italic: font,
    fontFallback: <pw.Font>[pw.Font.helvetica()],
  );
  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 44, 42, 44),
      maxPages: 200,
      theme: theme,
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      ),
      build: (context) => <pw.Widget>[
        pw.Text(
          document.title,
          style: pw.TextStyle(
            font: font,
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
            lineSpacing: 3,
          ),
        ),
        pw.SizedBox(height: 14),
        ..._metadataWidgets(document, font),
        ..._pdfSection('原始', document.rawBody, font, emptyLabel: '暂无原始内容'),
        ..._pdfSection('纲要', document.summaryBody, font, emptyLabel: '尚未生成'),
        ..._pdfSection('深度洞察', document.sproutBody, font, emptyLabel: '尚未生成'),
      ],
    ),
  );
  return pdf.save();
}

final class _DocumentRenderKey {
  const _DocumentRenderKey({
    required this.documentId,
    required this.revision,
    required this.widthPoints,
  });

  static _DocumentRenderKey? fromDocument(KnowledgeExportDocument document) {
    if (document.documentId == null || document.revision == null) return null;
    return _DocumentRenderKey(
      documentId: document.documentId!,
      revision: document.revision!,
      widthPoints: PdfPageFormat.a4.width.round(),
    );
  }

  final String documentId;
  final int revision;
  final int widthPoints;

  @override
  bool operator ==(Object other) =>
      other is _DocumentRenderKey &&
      other.documentId == documentId &&
      other.revision == revision &&
      other.widthPoints == widthPoints;

  @override
  int get hashCode => Object.hash(documentId, revision, widthPoints);
}

final class FileKnowledgeDocumentExportService
    implements KnowledgeDocumentExportService {
  FileKnowledgeDocumentExportService({
    KnowledgeDocumentSerializer? serializer,
    KnowledgeExportDirectoryResolver? directoryResolver,
    KnowledgeExportClock? clock,
    KnowledgeExportIdFactory? idFactory,
    TaskOrchestrator? taskOrchestrator,
    this.retention = const Duration(hours: 24),
  }) : _serializer = serializer ?? KnowledgeDocumentSerializer(),
       _directoryResolver = directoryResolver ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? _defaultExportId,
       _taskOrchestrator = taskOrchestrator;

  final KnowledgeDocumentSerializer _serializer;
  final KnowledgeExportDirectoryResolver _directoryResolver;
  final KnowledgeExportClock _clock;
  final KnowledgeExportIdFactory _idFactory;
  final TaskOrchestrator? _taskOrchestrator;
  final Set<String> _activeTaskKeys = <String>{};
  final Duration retention;
  bool _disposed = false;

  void releaseMemory() => _serializer.releaseMemory();

  @visibleForTesting
  int get cachedPdfRenderCount => _serializer.cachedPdfRenderCount;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final key in _activeTaskKeys.toList(growable: false)) {
      _taskOrchestrator?.cancel(key, reason: 'export-consumer-disposed');
    }
    _activeTaskKeys.clear();
    _serializer.releaseMemory();
  }

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepare(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
  ) async {
    if (format == KnowledgeExportFormat.archive) {
      return KnowledgeExportResult<PreparedKnowledgeExport>.failure(
        const KnowledgeExportFailure(
          code: 'KNOWLEDGE_EXPORT_FORMAT_INVALID',
          message: 'Knowledge document export format is invalid',
        ),
      );
    }
    if (_disposed) return _prepareFailure();
    if (format == KnowledgeExportFormat.markdown || _taskOrchestrator == null) {
      return _prepareDocument(document, format, null);
    }
    // performance-rfc: knowledge-pdf-export-budget
    final spec = TaskSpec(
      key: _knowledgePdfTaskKey(document),
      owner: 'knowledge-pdf-export',
      priority: TaskPriority.userBlocking,
      resources: const <TaskResource>{TaskResource.cpu, TaskResource.media},
      foregroundOnly: true,
      deadline: const Duration(minutes: 1),
    );
    return _runBudgeted(
      spec,
      (token) => _prepareDocument(document, format, token),
    );
  }

  Future<KnowledgeExportResult<PreparedKnowledgeExport>> _prepareDocument(
    KnowledgeExportDocument document,
    KnowledgeExportFormat format,
    AppTaskCancellationToken? cancellationToken,
  ) async {
    try {
      _ensureActive(cancellationToken);
      final bytes = switch (format) {
        KnowledgeExportFormat.markdown => Uint8List.fromList(
          utf8.encode(_serializer.serializeMarkdown(document)),
        ),
        KnowledgeExportFormat.pdf => await _serializer.serializePdf(
          document,
          cancellationToken: cancellationToken,
        ),
        KnowledgeExportFormat.archive => throw StateError('unreachable'),
      };
      _ensureActive(cancellationToken);
      return _prepareBytes(document.title, bytes, format, cancellationToken);
    } on AppTaskCancelledException {
      rethrow;
    } catch (_) {
      return _prepareFailure();
    }
  }

  @override
  Future<KnowledgeExportResult<PreparedKnowledgeExport>> prepareArchive({
    required String title,
    required Uint8List bytes,
  }) {
    if (_disposed) return Future.value(_prepareFailure());
    if (_taskOrchestrator == null) {
      return _prepareBytes(title, bytes, KnowledgeExportFormat.archive, null);
    }
    // performance-rfc: knowledge-zip-export-budget
    final spec = TaskSpec(
      key: _knowledgeArchiveTaskKey(title, bytes.lengthInBytes),
      owner: 'knowledge-zip-export',
      priority: TaskPriority.userBlocking,
      resources: const <TaskResource>{TaskResource.media},
      foregroundOnly: true,
      deadline: const Duration(seconds: 30),
    );
    return _runBudgeted(
      spec,
      (token) =>
          _prepareBytes(title, bytes, KnowledgeExportFormat.archive, token),
    );
  }

  Future<KnowledgeExportResult<PreparedKnowledgeExport>> _runBudgeted(
    TaskSpec spec,
    Future<KnowledgeExportResult<PreparedKnowledgeExport>> Function(
      AppTaskCancellationToken token,
    )
    body,
  ) async {
    final orchestrator = _taskOrchestrator;
    if (_disposed || orchestrator == null) return _prepareFailure();
    _activeTaskKeys.add(spec.key);
    try {
      return await orchestrator.schedule(spec, body);
    } catch (_) {
      return _prepareFailure();
    } finally {
      _activeTaskKeys.remove(spec.key);
    }
  }

  void _ensureActive(AppTaskCancellationToken? cancellationToken) {
    cancellationToken?.throwIfCancelled();
    if (_disposed) {
      throw StateError('KNOWLEDGE_EXPORT_SERVICE_DISPOSED');
    }
  }

  Future<KnowledgeExportResult<PreparedKnowledgeExport>> _prepareBytes(
    String title,
    Uint8List bytes,
    KnowledgeExportFormat format,
    AppTaskCancellationToken? cancellationToken,
  ) async {
    File? partFile;
    File? targetFile;
    Directory? exportDirectory;
    try {
      _ensureActive(cancellationToken);
      final now = _clock();
      final exportId = _idFactory(now);
      if (!_safeExportId.hasMatch(exportId)) {
        return KnowledgeExportResult<PreparedKnowledgeExport>.failure(
          const KnowledgeExportFailure(
            code: 'KNOWLEDGE_EXPORT_ID_INVALID',
            message: 'Knowledge export identifier is invalid',
          ),
        );
      }

      final root = await _directoryResolver();
      _ensureActive(cancellationToken);
      final cacheRoot = _knowledgeCacheRoot(root);
      await cacheRoot.create(recursive: true);
      _ensureActive(cancellationToken);
      await _deleteExpiredExports(cacheRoot, now);
      _ensureActive(cancellationToken);
      exportDirectory = Directory(_join(cacheRoot.path, exportId));
      final pathOccupied =
          await exportDirectory.exists() ||
          await FileSystemEntity.type(
                exportDirectory.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound;
      _ensureActive(cancellationToken);
      if (pathOccupied) {
        return KnowledgeExportResult<PreparedKnowledgeExport>.failure(
          const KnowledgeExportFailure(
            code: 'KNOWLEDGE_EXPORT_ID_COLLISION',
            message: 'Knowledge export identifier already exists',
          ),
        );
      }
      await exportDirectory.create(recursive: false);
      _ensureActive(cancellationToken);

      final fileName = '${_safeAsciiStem(title)}.${format.extension}';
      targetFile = File(_join(exportDirectory.path, fileName));
      partFile = File('${targetFile.path}.part');
      if (bytes.isEmpty) {
        throw const FileSystemException('Empty knowledge export');
      }
      _ensureActive(cancellationToken);
      await partFile.writeAsBytes(bytes, flush: true);
      _ensureActive(cancellationToken);
      final hasStagedBytes =
          await partFile.exists() && await partFile.length() > 0;
      _ensureActive(cancellationToken);
      if (!hasStagedBytes) {
        throw const FileSystemException('Knowledge export staging failed');
      }
      await partFile.rename(targetFile.path);
      _ensureActive(cancellationToken);
      final sizeBytes = await targetFile.length();
      if (sizeBytes <= 0) {
        throw const FileSystemException('Knowledge export is empty');
      }
      _ensureActive(cancellationToken);

      return KnowledgeExportResult<PreparedKnowledgeExport>.success(
        PreparedKnowledgeExport(
          opaqueExportRef:
              'app-private-export://knowledge/cache/$exportId/$fileName',
          displayName: '${_safeDisplayStem(title)}.${format.extension}',
          mimeType: format.mimeType,
          sizeBytes: sizeBytes,
          format: format,
        ),
      );
    } catch (error) {
      await _deleteFileIfPresent(partFile);
      await _deleteFileIfPresent(targetFile);
      await _deleteDirectoryIfEmpty(exportDirectory);
      if (error is AppTaskCancelledException) rethrow;
      return _prepareFailure();
    }
  }

  @override
  Future<void> discard(PreparedKnowledgeExport export) async {
    final match = _opaqueReference.firstMatch(export.opaqueExportRef);
    if (match == null) return;
    final exportId = match.group(1)!;
    try {
      final root = await _directoryResolver();
      final directory = Directory(
        _join(_knowledgeCacheRoot(root).path, exportId),
      );
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory) {
        await directory.delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(directory.path).delete();
      }
    } catch (_) {
      // Prepared exports are disposable; cleanup failures must not leak paths.
    }
  }

  Future<void> _deleteExpiredExports(Directory root, DateTime now) async {
    if (retention <= Duration.zero) return;
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory ||
            !_safeExportId.hasMatch(_basename(entity.path))) {
          continue;
        }
        final stat = await entity.stat();
        if (now.difference(stat.modified) > retention) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {
      // Stale cleanup is best effort and never blocks a new export.
    }
  }
}

KnowledgeExportResult<PreparedKnowledgeExport> _prepareFailure() =>
    KnowledgeExportResult<PreparedKnowledgeExport>.failure(
      const KnowledgeExportFailure(
        code: 'KNOWLEDGE_EXPORT_PREPARE_FAILED',
        message: 'Knowledge document export could not be prepared',
      ),
    );

String _knowledgePdfTaskKey(KnowledgeExportDocument document) {
  final identity = document.documentId ?? document.title;
  final revision =
      document.revision ?? document.updatedAt.microsecondsSinceEpoch;
  return _hashedExportTaskKey('pdf', '$identity\u0000$revision\u0000a4');
}

String _knowledgeArchiveTaskKey(String title, int sizeBytes) =>
    _hashedExportTaskKey('zip', '$title\u0000$sizeBytes');

String _hashedExportTaskKey(String kind, String identity) {
  final digest = sha256.convert(utf8.encode(identity)).toString();
  return 'knowledge:$kind-export:${digest.substring(0, 20)}';
}

void _appendMarkdownSection(
  StringBuffer buffer,
  String title,
  String body, {
  required String emptyLabel,
}) {
  final value = body.trim();
  buffer
    ..writeln()
    ..writeln('## $title')
    ..writeln()
    ..writeln(value.isEmpty ? '_${emptyLabel}_' : value);
}

List<pw.Widget> _metadataWidgets(
  KnowledgeExportDocument document,
  pw.Font font,
) {
  final rows = <MapEntry<String, String>>[
    MapEntry<String, String>('来源', document.sourceLabel),
    MapEntry<String, String>('更新时间', _formatDate(document.updatedAt)),
    if (document.tags.isNotEmpty)
      MapEntry<String, String>('标签', document.tags.join('、')),
    if (document.attachmentDisplayNames.isNotEmpty)
      MapEntry<String, String>('附件', document.attachmentDisplayNames.join('、')),
  ];
  return <pw.Widget>[
    pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: rows
            .map(
              (entry) => pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 3),
                child: pw.Text(
                  '${entry.key}：${entry.value}',
                  style: pw.TextStyle(font: font, fontSize: 10),
                ),
              ),
            )
            .toList(growable: false),
      ),
    ),
    pw.SizedBox(height: 18),
  ];
}

List<pw.Widget> _pdfSection(
  String title,
  String body,
  pw.Font font, {
  required String emptyLabel,
}) {
  return <pw.Widget>[
    pw.Header(
      level: 1,
      text: title,
      textStyle: pw.TextStyle(
        font: font,
        fontSize: 16,
        fontWeight: pw.FontWeight.bold,
      ),
    ),
    ..._markdownWidgets(body.trim().isEmpty ? emptyLabel : body, font),
    pw.SizedBox(height: 12),
  ];
}

List<pw.Widget> _markdownWidgets(String body, pw.Font font) {
  final document = HuahuoMarkdownDocument.parse(body);
  final style = pw.TextStyle(font: font, fontSize: 10.5, lineSpacing: 2);
  return _pdfMarkdownBlocks(document.blocks, style, font);
}

List<pw.Widget> _pdfMarkdownBlocks(
  List<HuahuoMarkdownBlock> blocks,
  pw.TextStyle style,
  pw.Font font, {
  pw.TextAlign textAlign = pw.TextAlign.left,
}) {
  final widgets = <pw.Widget>[];
  for (final block in blocks) {
    switch (block.kind) {
      case HuahuoMarkdownBlockKind.code:
        final lines = block.text.split('\n');
        for (var offset = 0; offset < lines.length; offset += 24) {
          widgets.add(
            pw.Container(
              width: double.infinity,
              margin: const pw.EdgeInsets.only(bottom: 7),
              padding: const pw.EdgeInsets.all(9),
              color: PdfColors.grey200,
              child: pw.Text(
                lines
                    .sublist(offset, (offset + 24).clamp(0, lines.length))
                    .join('\n'),
                style: style.copyWith(fontSize: 8.5, lineSpacing: 1.5),
              ),
            ),
          );
        }
      case HuahuoMarkdownBlockKind.table:
        widgets.add(_pdfMarkdownTable(block.table!, font));
      case HuahuoMarkdownBlockKind.divider:
        widgets.add(pw.Divider(color: PdfColors.grey400));
      case HuahuoMarkdownBlockKind.spacing:
        widgets.add(pw.SizedBox(height: 5));
      case HuahuoMarkdownBlockKind.alignment:
        widgets.addAll(
          _pdfMarkdownBlocks(
            block.children,
            style,
            font,
            textAlign: switch (block.marker) {
              'center' => pw.TextAlign.center,
              'right' => pw.TextAlign.right,
              _ => pw.TextAlign.left,
            },
          ),
        );
      case HuahuoMarkdownBlockKind.heading:
        widgets.addAll(
          _pdfMarkdownParagraphs(
            block.text,
            style.copyWith(
              fontSize: block.level <= 2 ? 14 : 12,
              fontWeight: pw.FontWeight.bold,
            ),
            textAlign: textAlign,
            padding: const pw.EdgeInsets.only(top: 7, bottom: 5),
          ),
        );
      case HuahuoMarkdownBlockKind.quote:
        for (final paragraph in _pdfMarkdownParagraphs(
          block.text,
          style.copyWith(
            fontSize: 10,
            fontStyle: pw.FontStyle.italic,
            color: PdfColors.grey700,
          ),
          textAlign: textAlign,
        )) {
          widgets.add(
            pw.Container(
              width: double.infinity,
              margin: const pw.EdgeInsets.only(bottom: 5),
              padding: const pw.EdgeInsets.fromLTRB(9, 5, 6, 5),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  left: pw.BorderSide(width: 2, color: PdfColors.grey500),
                ),
              ),
              child: paragraph,
            ),
          );
        }
      case HuahuoMarkdownBlockKind.bullet:
      case HuahuoMarkdownBlockKind.ordered:
      case HuahuoMarkdownBlockKind.task:
        final marker = switch (block.kind) {
          HuahuoMarkdownBlockKind.ordered => block.marker,
          HuahuoMarkdownBlockKind.task => block.checked ? '[x]' : '[ ]',
          _ => '-',
        };
        final paragraphs = _pdfMarkdownParagraphs(
          block.text,
          block.checked
              ? style.copyWith(decoration: pw.TextDecoration.lineThrough)
              : style,
          textAlign: textAlign,
        );
        for (var index = 0; index < paragraphs.length; index++) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 8, bottom: 4),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 22,
                    child: pw.Text(index == 0 ? marker : '', style: style),
                  ),
                  pw.Expanded(child: paragraphs[index]),
                ],
              ),
            ),
          );
        }
      case HuahuoMarkdownBlockKind.image:
        widgets.addAll(
          _pdfMarkdownParagraphs(
            block.text.isEmpty ? '图片' : block.text,
            style,
            textAlign: textAlign,
          ),
        );
      case HuahuoMarkdownBlockKind.paragraph:
        widgets.addAll(
          _pdfMarkdownParagraphs(block.text, style, textAlign: textAlign),
        );
    }
  }
  return widgets;
}

List<pw.Widget> _pdfMarkdownParagraphs(
  String source,
  pw.TextStyle style, {
  pw.TextAlign textAlign = pw.TextAlign.left,
  pw.EdgeInsets padding = const pw.EdgeInsets.only(bottom: 7),
}) {
  final paragraphs = <pw.Widget>[];
  final spans = <pw.InlineSpan>[];
  var length = 0;
  void flush() {
    if (spans.isEmpty) return;
    paragraphs.add(
      pw.Padding(
        padding: padding,
        child: pw.RichText(
          textAlign: textAlign,
          text: pw.TextSpan(style: style, children: List.of(spans)),
        ),
      ),
    );
    spans.clear();
    length = 0;
  }

  void append(List<HuahuoMarkdownInline> nodes, pw.TextStyle inherited) {
    for (final node in nodes) {
      final effective = switch (node.kind) {
        HuahuoMarkdownInlineKind.foreground => inherited.copyWith(
          color: PdfColor.fromHex(node.value),
        ),
        HuahuoMarkdownInlineKind.background => inherited.copyWith(
          background: pw.BoxDecoration(color: PdfColor.fromHex(node.value)),
        ),
        HuahuoMarkdownInlineKind.underline => inherited.copyWith(
          decoration: pw.TextDecoration.underline,
        ),
        HuahuoMarkdownInlineKind.strike => inherited.copyWith(
          decoration: pw.TextDecoration.lineThrough,
        ),
        HuahuoMarkdownInlineKind.bold => inherited.copyWith(
          fontWeight: pw.FontWeight.bold,
        ),
        HuahuoMarkdownInlineKind.italic => inherited.copyWith(
          fontStyle: pw.FontStyle.italic,
        ),
        HuahuoMarkdownInlineKind.link => inherited.copyWith(
          color: PdfColors.blue700,
          decoration: pw.TextDecoration.underline,
        ),
        HuahuoMarkdownInlineKind.code => inherited.copyWith(
          background: const pw.BoxDecoration(color: PdfColors.grey200),
        ),
        HuahuoMarkdownInlineKind.text => inherited,
      };
      if (node.children.isNotEmpty) {
        append(node.children, effective);
        continue;
      }
      final runes = node.text.runes.toList(growable: false);
      var offset = 0;
      while (offset < runes.length) {
        final end = (offset + 900 - length).clamp(0, runes.length);
        spans.add(
          pw.TextSpan(
            text: String.fromCharCodes(runes.sublist(offset, end)),
            style: effective,
          ),
        );
        length += end - offset;
        offset = end;
        if (length == 900) flush();
      }
    }
  }

  append(parseHuahuoMarkdownInline(source), style);
  flush();
  return paragraphs;
}

pw.Widget _pdfMarkdownTable(HuahuoMarkdownTable table, pw.Font font) {
  final headerStyle = pw.TextStyle(
    font: font,
    fontSize: 8.5,
    fontWeight: pw.FontWeight.bold,
    lineSpacing: 1.3,
  );
  final cellStyle = pw.TextStyle(font: font, fontSize: 8.2, lineSpacing: 1.3);
  pw.Widget cell(String value, {required bool header}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: _pdfMarkdownParagraphs(
        value,
        header ? headerStyle : cellStyle,
        padding: pw.EdgeInsets.zero,
      ),
    ),
  );
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 9),
    child: pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey500, width: .45),
      columnWidths: <int, pw.TableColumnWidth>{
        for (var index = 0; index < table.headers.length; index += 1)
          index: const pw.FlexColumnWidth(),
      },
      children: <pw.TableRow>[
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: <pw.Widget>[
            for (final value in table.headers) cell(value, header: true),
          ],
        ),
        for (final row in table.rows)
          pw.TableRow(
            children: <pw.Widget>[
              for (var index = 0; index < table.headers.length; index += 1)
                cell(index < row.length ? row[index] : '', header: false),
            ],
          ),
      ],
    ),
  );
}

String _formatDate(DateTime value) => value.toIso8601String();

Directory _knowledgeCacheRoot(Directory root) {
  return Directory(
    _joinAll(root.path, const <String>[
      'HuahuoAI',
      'TemporaryTransfers',
      'knowledge',
      'cache',
    ]),
  );
}

String _safeAsciiStem(String title) {
  final normalized = title
      .trim()
      .replaceAll(RegExp('[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
  if (normalized.isEmpty) return 'knowledge';
  return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
}

String _safeDisplayStem(String title) {
  final runes = title
      .trim()
      .replaceAll(RegExp(r'[\\/\u0000-\u001f\u007f]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^\.+'), '')
      .runes
      .take(80)
      .toList(growable: false);
  final value = String.fromCharCodes(runes).trim();
  return value.isEmpty ? '知识笔记' : value;
}

String _defaultExportId(DateTime now) {
  _exportSequence = (_exportSequence + 1) & 0xFFFFFF;
  return 'export-${now.microsecondsSinceEpoch}-${_exportSequence.toRadixString(36)}';
}

Future<void> _deleteFileIfPresent(File? file) async {
  if (file == null) return;
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<void> _deleteDirectoryIfEmpty(Directory? directory) async {
  if (directory == null) return;
  try {
    if (await directory.exists() && await directory.list().isEmpty) {
      await directory.delete();
    }
  } catch (_) {}
}

String _join(String left, String right) =>
    '$left${Platform.pathSeparator}$right';

String _joinAll(String root, List<String> segments) {
  var value = root;
  for (final segment in segments) {
    value = _join(value, segment);
  }
  return value;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

final RegExp _safeExportId = RegExp(r'^export-[A-Za-z0-9_-]{1,80}$');
final RegExp _opaqueReference = RegExp(
  r'^app-private-export://knowledge/cache/(export-[A-Za-z0-9_-]{1,80})/[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.(?:md|pdf|zip)$',
  caseSensitive: false,
);
int _exportSequence = 0;
