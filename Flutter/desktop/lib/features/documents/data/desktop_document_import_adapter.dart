import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_document_import_port.dart';

/// Imports verified source bytes through the public Resource -> ingestion ->
/// HNote workflow. Local paths remain inside this process.
final class RemoteDesktopDocumentImportPort
    implements DesktopDocumentImportPort {
  RemoteDesktopDocumentImportPort(
    ApiClient apiClient, {
    Future<void> Function(Duration)? delay,
    ObjectUploadTransport? objectUploadTransport,
    this.maxPollAttempts = 90,
    this.pollInterval = const Duration(seconds: 2),
  }) : _apiClient = apiClient,
       _workspace = WorkspaceContentClient(apiClient),
       _delay = delay ?? ((duration) => Future<void>.delayed(duration)),
       _objectUploadTransport = objectUploadTransport;

  static const _maximumBytes = 8 * 1024 * 1024;

  final ApiClient _apiClient;
  final WorkspaceContentClient _workspace;
  final Future<void> Function(Duration) _delay;
  final ObjectUploadTransport? _objectUploadTransport;
  final int maxPollAttempts;
  final Duration pollInterval;

  @override
  Future<DesktopServiceResult<DesktopDocumentImportResult>> importDocument(
    DesktopDocumentImportRequest request,
  ) async {
    final prepared = await _prepare(request);
    if (prepared is DesktopServiceResult<DesktopDocumentImportResult>) {
      return prepared;
    }
    final source = prepared as _PreparedDesktopDocument;
    try {
      final hash = (await sha256.bind(source.file.openRead()).first).toString();
      final metadata = UploadMetadata(
        sourceScene: 'note_import',
        fileName: source.fileName,
        mimeType: source.format.mimeType,
        sizeBytes: source.sizeBytes,
        durationSeconds: 0,
        appPrivateUri:
            'app-private://desktop-document-import/$hash.${source.format.extension}',
        sha256: hash,
        workspaceId: source.workspaceId,
      );
      final uploader = UploadClient(
        apiClient: _apiClient,
        objectTransport:
            _objectUploadTransport ??
            HttpObjectUploadTransport(openRead: (_) => source.file.openRead()),
      );
      final actionKey = 'desktop-document-$hash';
      final token = await uploader.requestUploadToken(
        metadata: metadata,
        idempotencyKey: '$actionKey-token',
      );
      final uploadToken = token.value;
      final resourceId = _safeId(uploadToken?.resourceId);
      if (!token.ok || uploadToken == null || resourceId == null) {
        return _uploadFailure(
          token.error,
          fallbackCode: 'DESKTOP_DOCUMENT_UPLOAD_TOKEN_FAILED',
          fallbackMessage: '无法获取文档上传凭证',
        );
      }
      final uploaded = await uploader.uploadToObjectStore(
        token: uploadToken,
        metadata: metadata,
      );
      if (!uploaded.ok) {
        return _uploadFailure(
          uploaded.error,
          fallbackCode: 'DESKTOP_DOCUMENT_OBJECT_UPLOAD_FAILED',
          fallbackMessage: '文档上传失败',
        );
      }
      final completed = await uploader.completeUpload(
        uploadId: uploadToken.uploadId,
        metadata: metadata,
        idempotencyKey: '$actionKey-complete',
      );
      final resource = completed.value;
      if (!completed.ok ||
          resource == null ||
          resource.uploadId != uploadToken.uploadId ||
          resource.resourceId != resourceId) {
        return _uploadFailure(
          completed.error,
          fallbackCode: 'DESKTOP_DOCUMENT_UPLOAD_COMPLETE_FAILED',
          fallbackMessage: '文档上传未完成',
        );
      }
      final created = await _createIngestion(
        workspaceId: source.workspaceId,
        resourceId: resourceId,
        idempotencyKey: '$actionKey-ingestion',
      );
      final ingestion = created.data;
      if (!created.ok || ingestion == null) {
        return _apiFailure(
          created.error,
          fallbackCode: 'DESKTOP_DOCUMENT_INGESTION_CREATE_FAILED',
          fallbackMessage: '文档已上传，但无法开始导入',
        );
      }
      final noteId = await _waitForPromotion(
        workspaceId: source.workspaceId,
        title: _titleFromFileName(source.fileName),
        actionKey: actionKey,
        initial: ingestion,
      );
      if (!noteId.isSuccess || noteId.data == null) {
        return DesktopServiceResult<DesktopDocumentImportResult>.failure(
          code: noteId.code,
          message: noteId.message,
          retryable: noteId.retryable,
        );
      }
      final readback = await _workspace.note(source.workspaceId, noteId.data!);
      if (!readback.ok || readback.data == null) {
        return _apiFailure(
          readback.error,
          fallbackCode: 'DESKTOP_DOCUMENT_READBACK_FAILED',
          fallbackMessage: '文档已导入，但暂时无法读取结果',
        );
      }
      final note = readback.data!;
      if (note.noteId != noteId.data) {
        return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
          code: 'DESKTOP_DOCUMENT_READBACK_MISMATCH',
          message: '文档导入读取结果不匹配',
          retryable: true,
        );
      }
      return DesktopServiceResult<DesktopDocumentImportResult>.success(
        DesktopDocumentImportResult(
          noteId: note.noteId,
          title: note.title,
          fileName: source.fileName,
          format: source.format,
          rawMarkdown: note.raw.markdown,
        ),
      );
    } on FileSystemException {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'DESKTOP_DOCUMENT_FILE_READ_FAILED',
        message: '读取所选文档失败，请重新选择文件',
        retryable: true,
      );
    } on Object {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'DESKTOP_DOCUMENT_IMPORT_FAILED',
        message: '文档导入失败，请稍后重试',
        retryable: true,
      );
    }
  }

  Future<Object> _prepare(DesktopDocumentImportRequest request) async {
    final workspaceId = _safeId(request.workspaceId);
    final fileName = request.fileName.trim();
    final format = DesktopDocumentImportFormat.fromFileName(fileName);
    if (workspaceId == null || !_safeFileName(fileName) || format == null) {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'DESKTOP_DOCUMENT_IMPORT_INVALID',
        message: '请选择 TXT、Markdown、CSV、JSON、PDF、DOCX、PPTX 或 XLSX 文件',
      );
    }
    final file = File(request.filePath.trim());
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'DESKTOP_DOCUMENT_FILE_INVALID',
        message: '所选文档不可读取',
      );
    }
    final sizeBytes = await file.length();
    if (sizeBytes <= 0 || sizeBytes > _maximumBytes) {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'DESKTOP_DOCUMENT_SIZE_INVALID',
        message: '文档大小不符合导入要求',
      );
    }
    return _PreparedDesktopDocument(
      file: file,
      fileName: fileName,
      format: format,
      workspaceId: workspaceId,
      sizeBytes: sizeBytes,
    );
  }

  Future<DesktopServiceResult<String>> _waitForPromotion({
    required String workspaceId,
    required String title,
    required String actionKey,
    required _DesktopIngestionSnapshot initial,
  }) async {
    var current = initial;
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      if (current.status == 'promoted' && current.promotedNoteId != null) {
        return DesktopServiceResult<String>.success(current.promotedNoteId!);
      }
      if (_terminalStatuses.contains(current.status)) {
        return DesktopServiceResult<String>.failure(
          code: current.failureCode ?? 'DESKTOP_DOCUMENT_INGESTION_FAILED',
          message: '服务端未能导入此文档',
        );
      }
      if (_readyStatuses.contains(current.status)) {
        final promoted = await _promoteIngestion(
          workspaceId: workspaceId,
          ingestionId: current.ingestionId,
          title: title,
          idempotencyKey: '$actionKey-promote',
        );
        if (!promoted.ok || promoted.data == null) {
          return _apiFailure(
            promoted.error,
            fallbackCode: 'DESKTOP_DOCUMENT_INGESTION_PROMOTE_FAILED',
            fallbackMessage: '文档解析完成，但无法生成笔记',
          );
        }
        return DesktopServiceResult<String>.success(promoted.data!);
      }
      if (attempt + 1 >= maxPollAttempts) break;
      await _delay(pollInterval);
      final polled = await _getIngestion(
        workspaceId: workspaceId,
        ingestionId: current.ingestionId,
      );
      if (!polled.ok || polled.data == null) {
        return _apiFailure(
          polled.error,
          fallbackCode: 'DESKTOP_DOCUMENT_INGESTION_POLL_FAILED',
          fallbackMessage: '无法读取文档导入进度',
        );
      }
      current = polled.data!;
    }
    return const DesktopServiceResult<String>.failure(
      code: 'DESKTOP_DOCUMENT_INGESTION_TIMEOUT',
      message: '文档正在服务端处理中，请稍后刷新资产查看',
      retryable: true,
    );
  }

  Future<ApiResult<_DesktopIngestionSnapshot>> _createIngestion({
    required String workspaceId,
    required String resourceId,
    required String idempotencyKey,
  }) => _apiClient.request<_DesktopIngestionSnapshot>(
    ApiRequestOptions<_DesktopIngestionSnapshot>(
      endpointId: 'createWorkspaceNoteIngestion',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: <String, Object?>{'resourceId': resourceId},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseIngestion,
    ),
  );

  Future<ApiResult<_DesktopIngestionSnapshot>> _getIngestion({
    required String workspaceId,
    required String ingestionId,
  }) => _apiClient.request<_DesktopIngestionSnapshot>(
    ApiRequestOptions<_DesktopIngestionSnapshot>(
      endpointId: 'workspaceNoteIngestion',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'ingestionId': ingestionId,
      },
      parseData: _parseIngestion,
    ),
  );

  Future<ApiResult<String>> _promoteIngestion({
    required String workspaceId,
    required String ingestionId,
    required String title,
    required String idempotencyKey,
  }) => _apiClient.request<String>(
    ApiRequestOptions<String>(
      endpointId: 'promoteWorkspaceNoteIngestion',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'ingestionId': ingestionId,
      },
      body: <String, Object?>{'title': title},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parsePromotedNoteId,
    ),
  );
}

final class _PreparedDesktopDocument {
  const _PreparedDesktopDocument({
    required this.file,
    required this.fileName,
    required this.format,
    required this.workspaceId,
    required this.sizeBytes,
  });

  final File file;
  final String fileName;
  final DesktopDocumentImportFormat format;
  final String workspaceId;
  final int sizeBytes;
}

final class _DesktopIngestionSnapshot {
  const _DesktopIngestionSnapshot({
    required this.ingestionId,
    required this.status,
    this.promotedNoteId,
    this.failureCode,
  });

  final String ingestionId;
  final String status;
  final String? promotedNoteId;
  final String? failureCode;
}

_DesktopIngestionSnapshot? _parseIngestion(Object? value) {
  final data = asObjectMap(value);
  final raw = data == null ? null : asObjectMap(data['ingestion']) ?? data;
  if (raw == null) return null;
  final ingestionId = _safeId(raw['ingestionId']);
  final status = _safeStatus(raw['status']);
  if (ingestionId == null || status == null) return null;
  final safeError = asObjectMap(raw['safeError']);
  return _DesktopIngestionSnapshot(
    ingestionId: ingestionId,
    status: status,
    promotedNoteId: _safeId(raw['promotedNoteId']),
    failureCode:
        _safeErrorCode(raw['failureCode']) ??
        _safeErrorCode(safeError?['code']),
  );
}

String? _parsePromotedNoteId(Object? value) {
  final data = asObjectMap(value);
  final note = asObjectMap(data?['note']);
  return _safeId(note?['noteId'] ?? data?['noteId']);
}

DesktopServiceResult<T> _uploadFailure<T>(
  AppFailure? error, {
  required String fallbackCode,
  required String fallbackMessage,
}) => DesktopServiceResult<T>.failure(
  code: error?.code ?? fallbackCode,
  message: _safeMessage(error?.message) ?? fallbackMessage,
  retryable: error?.isRetryable ?? true,
);

DesktopServiceResult<T> _apiFailure<T>(
  AppFailure? error, {
  required String fallbackCode,
  required String fallbackMessage,
}) => DesktopServiceResult<T>.failure(
  code: error?.code ?? fallbackCode,
  message: _safeMessage(error?.message) ?? fallbackMessage,
  retryable: error?.isRetryable ?? true,
);

String _titleFromFileName(String value) {
  final dot = value.lastIndexOf('.');
  final stem = (dot > 0 ? value.substring(0, dot) : value).trim();
  if (stem.isEmpty) return '导入资料';
  final runes = stem.runes.toList(growable: false);
  return runes.length <= 80 ? stem : String.fromCharCodes(runes.take(80));
}

bool _safeFileName(String value) =>
    value.isNotEmpty &&
    value.length <= 120 &&
    !value.contains('/') &&
    !value.contains('\\') &&
    !value.runes.any(_isControl);

String? _safeId(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)
      ? text
      : null;
}

String? _safeStatus(Object? value) {
  if (value is! String) return null;
  final text = value.trim().toLowerCase();
  return RegExp(r'^[a-z_]{1,64}$').hasMatch(text) ? text : null;
}

String? _safeErrorCode(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(text) ? text : null;
}

String? _safeMessage(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.runes.length > 280 || text.runes.any(_isControl)
      ? null
      : text;
}

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

const _readyStatuses = <String>{'ready', 'ready_to_promote'};
const _terminalStatuses = <String>{
  'failed',
  'quarantined',
  'expired',
  'cancelled',
};
