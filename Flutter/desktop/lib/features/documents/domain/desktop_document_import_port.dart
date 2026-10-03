import '../../../shared/services/desktop_service_result.dart';

enum DesktopDocumentImportFormat {
  text(extension: 'txt', mimeType: 'text/plain', displayLabel: 'TXT'),
  markdown(
    extension: 'md',
    mimeType: 'text/markdown',
    displayLabel: 'Markdown',
  ),
  csv(extension: 'csv', mimeType: 'text/csv', displayLabel: 'CSV'),
  json(extension: 'json', mimeType: 'application/json', displayLabel: 'JSON'),
  pdf(extension: 'pdf', mimeType: 'application/pdf', displayLabel: 'PDF'),
  docx(
    extension: 'docx',
    mimeType:
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    displayLabel: 'DOCX',
  ),
  pptx(
    extension: 'pptx',
    mimeType:
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    displayLabel: 'PPTX',
  ),
  xlsx(
    extension: 'xlsx',
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    displayLabel: 'XLSX',
  );

  const DesktopDocumentImportFormat({
    required this.extension,
    required this.mimeType,
    required this.displayLabel,
  });

  final String extension;
  final String mimeType;
  final String displayLabel;

  static DesktopDocumentImportFormat? fromFileName(String value) {
    final normalized = value.trim();
    final dot = normalized.lastIndexOf('.');
    if (dot < 1 || dot == normalized.length - 1) return null;
    final extension = normalized.substring(dot + 1).toLowerCase();
    if (extension == 'markdown') return DesktopDocumentImportFormat.markdown;
    for (final format in values) {
      if (format.extension == extension) return format;
    }
    return null;
  }

  static List<String> get supportedExtensions => List<String>.unmodifiable(
    <String>[for (final format in values) format.extension, 'markdown'],
  );
}

final class DesktopDocumentImportRequest {
  const DesktopDocumentImportRequest({
    required this.filePath,
    required this.fileName,
    required this.workspaceId,
  });

  final String filePath;
  final String fileName;
  final String workspaceId;
}

final class DesktopDocumentImportResult {
  const DesktopDocumentImportResult({
    required this.noteId,
    required this.title,
    required this.fileName,
    required this.format,
    required this.rawMarkdown,
  });

  final String noteId;
  final String title;
  final String fileName;
  final DesktopDocumentImportFormat format;
  final String rawMarkdown;
}

abstract interface class DesktopDocumentImportPort {
  Future<DesktopServiceResult<DesktopDocumentImportResult>> importDocument(
    DesktopDocumentImportRequest request,
  );
}

final class UnavailableDesktopDocumentImportPort
    implements DesktopDocumentImportPort {
  const UnavailableDesktopDocumentImportPort();

  @override
  Future<DesktopServiceResult<DesktopDocumentImportResult>> importDocument(
    DesktopDocumentImportRequest request,
  ) async =>
      const DesktopServiceResult<DesktopDocumentImportResult>.unavailable(
        code: 'DESKTOP_DOCUMENT_IMPORT_UNAVAILABLE',
        message: '文档导入服务暂不可用',
      );
}
