const maxDocumentImportBytes = 100 * 1024 * 1024;

enum DocumentImportFormat {
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

  const DocumentImportFormat({
    required this.extension,
    required this.mimeType,
    required this.displayLabel,
  });

  final String extension;
  final String mimeType;
  final String displayLabel;

  static DocumentImportFormat? fromFileName(String value) {
    final dot = value.trim().lastIndexOf('.');
    if (dot < 0 || dot == value.trim().length - 1) return null;
    return fromExtension(value.trim().substring(dot + 1));
  }

  static DocumentImportFormat? fromExtension(String value) {
    final normalized = value.trim().toLowerCase();
    for (final format in values) {
      if (format.extension == normalized) {
        return format;
      }
    }
    return null;
  }

  static List<String> get supportedExtensions => List<String>.unmodifiable(
    <String>[for (final format in values) format.extension],
  );

  static List<String> get supportedMimeTypes => List<String>.unmodifiable(
    <String>[for (final format in values) format.mimeType],
  );
}
