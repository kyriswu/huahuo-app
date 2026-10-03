import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/upload_client.dart';
import '../../../core/native/native_file_port.dart';
import '../domain/chat_context.dart';
import '../domain/chat_models.dart';

enum ChatFileAttachmentStatus { uploading, ready, failed }

enum ChatFileAttachmentKind { file, image, video }

@immutable
final class ChatFileAttachment {
  const ChatFileAttachment({
    required this.localId,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.kind,
    this.resourceId,
    this.errorCode,
    this.localPreviewPath,
  });

  final String localId;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final ChatFileAttachmentStatus status;
  final ChatFileAttachmentKind kind;
  final String? resourceId;
  final String? errorCode;
  final String? localPreviewPath;

  bool get isImage => kind == ChatFileAttachmentKind.image;
  bool get isVideo => kind == ChatFileAttachmentKind.video;

  bool get isReady =>
      status == ChatFileAttachmentStatus.ready &&
      resourceId != null &&
      isSafeChatContextIdentifier(resourceId!);

  ChatFileAttachment copyWith({
    ChatFileAttachmentStatus? status,
    String? resourceId,
    String? errorCode,
    bool clearResourceId = false,
    bool clearError = false,
  }) => ChatFileAttachment(
    localId: localId,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    status: status ?? this.status,
    resourceId: clearResourceId ? null : resourceId ?? this.resourceId,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    kind: kind,
    localPreviewPath: localPreviewPath,
  );
}

/// Uploads current-turn chat files without exposing their local paths to chat.
///
/// A completed item becomes either a canonical `file` or `image` input part.
/// The uploader itself never creates a message, a Run, or a note.
final class ChatFileAttachmentUploader extends ChangeNotifier {
  ChatFileAttachmentUploader({
    required NativeFilePort nativeFilePort,
    required ApiClient apiClient,
    required String? Function() workspaceId,
    ObjectUploadTransport? objectUploadTransport,
  }) : _nativeFilePort = nativeFilePort, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _apiClient = apiClient,
       // ignore: prefer_initializing_formals
       _workspaceId = workspaceId,
       // ignore: prefer_initializing_formals
       _objectUploadTransport = objectUploadTransport;

  static const _maxFiles = 16;
  static const _maxImages = 9;
  static const _maxFileBytes = 50 * 1024 * 1024;
  static const _maxImageBytes = 50 * 1024 * 1024;
  static const _maxVideoBytes = 4 * 1024 * 1024 * 1024;
  static const _imageMimes = <String>{'image/jpeg', 'image/png', 'image/webp'};
  static const _videoMimes = <String>{
    'video/mp4',
    'video/quicktime',
    'video/webm',
  };

  final NativeFilePort _nativeFilePort;
  final ApiClient _apiClient;
  final String? Function() _workspaceId;
  final ObjectUploadTransport? _objectUploadTransport;
  final List<ChatFileAttachment> _attachments = <ChatFileAttachment>[];
  final Map<String, _PickedChatAttachment> _pickedByLocalId =
      <String, _PickedChatAttachment>{};
  final Map<String, int> _attemptByLocalId = <String, int>{};
  var _sequence = 0;
  var _pickerInFlight = false;
  var _disposed = false;

  List<ChatFileAttachment> get attachments =>
      List<ChatFileAttachment>.unmodifiable(_attachments);

  List<ChatFileAttachment> get readyAttachments =>
      List<ChatFileAttachment>.unmodifiable(
        _attachments.where((attachment) => attachment.isReady),
      );

  List<ChatResourceAttachment> get readyResourceAttachments =>
      List<ChatResourceAttachment>.unmodifiable(
        _attachments
            .where((attachment) => attachment.isReady && !attachment.isImage)
            .map(
              (attachment) => ChatResourceAttachment(
                kind: attachment.isVideo
                    ? ChatResourceAttachmentKind.video
                    : ChatResourceAttachmentKind.file,
                resourceId: attachment.resourceId!,
                displayName: attachment.displayName,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
              ),
            ),
      );

  bool get isUploading => _attachments.any(
    (attachment) => attachment.status == ChatFileAttachmentStatus.uploading,
  );

  bool get hasFailures => _attachments.any(
    (attachment) => attachment.status == ChatFileAttachmentStatus.failed,
  );

  Future<AppFailure?> pickAndUploadFiles() async {
    if (_disposed || _pickerInFlight) return null;
    _pickerInFlight = true;
    late final NativeFileResult<List<PickedDocumentFile>> picked;
    try {
      picked = await _nativeFilePort.pickDocumentFiles();
    } finally {
      _pickerInFlight = false;
    }
    if (_disposed) return null;
    final files = picked.value;
    if (!picked.ok || files == null || files.isEmpty) {
      if (picked.cancelled) return null;
      return picked.error ?? _failure('CHAT_FILE_PICK_EMPTY');
    }
    return uploadPickedFiles(files);
  }

  Future<AppFailure?> uploadPickedFiles(
    Iterable<PickedDocumentFile> files,
  ) async {
    if (_disposed) return null;
    final documents = files.map(_PickedChatAttachment.fromDocument).toList();
    if (documents.isEmpty ||
        _attachments.length + documents.length > _maxFiles) {
      return _failure('CHAT_ATTACHMENT_LIMIT_EXCEEDED');
    }
    await _appendAndUpload(documents);
    return null;
  }

  Future<AppFailure?> pickAndUploadImages() =>
      _pickAndUploadImages(source: NativeMediaSource.gallery);

  Future<AppFailure?> pickAndUploadCameraImage() =>
      _pickAndUploadImages(source: NativeMediaSource.camera);

  Future<AppFailure?> _pickAndUploadImages({
    required NativeMediaSource source,
  }) async {
    if (_disposed || _pickerInFlight) return null;
    _pickerInFlight = true;
    late final NativeFileResult<List<PickedMediaFile>> picked;
    try {
      picked = await _nativeFilePort.pickMediaFiles(
        kind: NativeMediaKind.image,
        source: source,
      );
    } finally {
      _pickerInFlight = false;
    }
    if (_disposed) return null;
    final files = picked.value;
    if (!picked.ok || files == null || files.isEmpty) {
      if (picked.cancelled) return null;
      return picked.error ?? _failure('CHAT_IMAGE_PICK_EMPTY');
    }
    return uploadPickedImages(files);
  }

  Future<AppFailure?> pickAndUploadVideos() async {
    return _pickAndUploadVideos(source: NativeMediaSource.gallery);
  }

  Future<AppFailure?> pickAndUploadVideoFiles() async {
    return _pickAndUploadVideos(source: NativeMediaSource.files);
  }

  Future<AppFailure?> _pickAndUploadVideos({
    required NativeMediaSource source,
  }) async {
    if (_disposed || _pickerInFlight) return null;
    _pickerInFlight = true;
    late final NativeFileResult<List<PickedMediaFile>> picked;
    try {
      picked = await _nativeFilePort.pickMediaFiles(
        kind: NativeMediaKind.video,
        source: source,
      );
    } finally {
      _pickerInFlight = false;
    }
    if (_disposed) return null;
    final files = picked.value;
    if (!picked.ok || files == null || files.isEmpty) {
      if (picked.cancelled) return null;
      return picked.error ?? _failure('CHAT_VIDEO_PICK_EMPTY');
    }
    return uploadPickedVideos(files);
  }

  Future<AppFailure?> uploadPickedImages(
    Iterable<PickedMediaFile> files,
  ) async {
    if (_disposed) return null;
    final images = <_PickedChatAttachment>[];
    for (final file in files) {
      if (file.kind != NativeMediaKind.image ||
          !_imageMimes.contains(file.mimeType.trim().toLowerCase())) {
        return _failure('CHAT_IMAGE_UNSUPPORTED_FILE');
      }
      images.add(_PickedChatAttachment.fromImage(file));
    }
    final existingImageCount = _attachments
        .where((attachment) => attachment.isImage)
        .length;
    if (images.isEmpty || existingImageCount + images.length > _maxImages) {
      return _failure('CHAT_IMAGE_LIMIT_EXCEEDED');
    }
    if (_attachments.length + images.length > _maxFiles) {
      return _failure('CHAT_ATTACHMENT_LIMIT_EXCEEDED');
    }
    await _appendAndUpload(images);
    return null;
  }

  Future<AppFailure?> uploadPickedVideos(
    Iterable<PickedMediaFile> files,
  ) async {
    if (_disposed) return null;
    final videos = <_PickedChatAttachment>[];
    for (final file in files) {
      if (file.kind != NativeMediaKind.video ||
          !_videoMimes.contains(file.mimeType.trim().toLowerCase())) {
        return _failure('CHAT_VIDEO_UNSUPPORTED_FILE');
      }
      videos.add(_PickedChatAttachment.fromVideo(file));
    }
    if (videos.isEmpty || _attachments.length + videos.length > _maxFiles) {
      return _failure('CHAT_ATTACHMENT_LIMIT_EXCEEDED');
    }
    await _appendAndUpload(videos);
    return null;
  }

  Future<void> _appendAndUpload(Iterable<_PickedChatAttachment> files) async {
    for (final file in files) {
      if (_disposed || _attachments.length >= _maxFiles) break;
      final localId = _nextLocalId(file);
      _pickedByLocalId[localId] = file;
      _attemptByLocalId[localId] = 1;
      _attachments.add(
        ChatFileAttachment(
          localId: localId,
          displayName: file.displayName,
          mimeType: file.mimeType,
          sizeBytes: file.sizeBytes,
          status: ChatFileAttachmentStatus.uploading,
          kind: file.kind,
          localPreviewPath: file.kind == ChatFileAttachmentKind.image
              ? file.sourcePath
              : null,
        ),
      );
      _notifyListenersIfActive();
      await _upload(localId, attempt: 1);
    }
  }

  Future<void> retry(String localId) async {
    if (_disposed ||
        !_pickedByLocalId.containsKey(localId) ||
        _find(localId).status != ChatFileAttachmentStatus.failed) {
      return;
    }
    final attempt = (_attemptByLocalId[localId] ?? 0) + 1;
    _attemptByLocalId[localId] = attempt;
    _replace(
      localId,
      _find(localId).copyWith(
        status: ChatFileAttachmentStatus.uploading,
        clearResourceId: true,
        clearError: true,
      ),
    );
    _notifyListenersIfActive();
    await _upload(localId, attempt: attempt);
  }

  void remove(String localId) {
    if (_disposed) return;
    _attachments.removeWhere((attachment) => attachment.localId == localId);
    _pickedByLocalId.remove(localId);
    _attemptByLocalId.remove(localId);
    _notifyListenersIfActive();
  }

  void clearReady() {
    if (_disposed) return;
    final readyIds = <String>{
      for (final attachment in _attachments)
        if (attachment.isReady) attachment.localId,
    };
    if (readyIds.isEmpty) return;
    _attachments.removeWhere(
      (attachment) => readyIds.contains(attachment.localId),
    );
    for (final localId in readyIds) {
      _pickedByLocalId.remove(localId);
      _attemptByLocalId.remove(localId);
    }
    _notifyListenersIfActive();
  }

  void clearAll() {
    if (_disposed || _attachments.isEmpty) return;
    _attachments.clear();
    _pickedByLocalId.clear();
    _attemptByLocalId.clear();
    _notifyListenersIfActive();
  }

  Future<void> _upload(String localId, {required int attempt}) async {
    final file = _pickedByLocalId[localId];
    if (_disposed || file == null) return;
    try {
      final sourcePath = file.sourcePath.trim();
      if (sourcePath.isEmpty) {
        return _failUpload(localId, attempt, 'CHAT_ATTACHMENT_SOURCE_MISSING');
      }
      final source = File(sourcePath);
      final exists = await source.exists();
      if (!_isCurrentAttempt(localId, attempt)) return;
      if (!exists) {
        return _failUpload(localId, attempt, 'CHAT_ATTACHMENT_SOURCE_MISSING');
      }
      final actualSize = await source.length();
      if (!_isCurrentAttempt(localId, attempt)) return;
      final maximumSize = switch (file.kind) {
        ChatFileAttachmentKind.image => _maxImageBytes,
        ChatFileAttachmentKind.video => _maxVideoBytes,
        ChatFileAttachmentKind.file => _maxFileBytes,
      };
      if (actualSize <= 0 ||
          actualSize != file.sizeBytes ||
          actualSize > maximumSize) {
        return _failUpload(localId, attempt, 'CHAT_ATTACHMENT_SIZE_INVALID');
      }
      final digest = (await sha256.bind(source.openRead()).first).toString();
      if (!_isCurrentAttempt(localId, attempt)) return;
      final expectedDigest = file.contentHash?.trim().toLowerCase();
      if (expectedDigest != null &&
          expectedDigest.isNotEmpty &&
          expectedDigest != digest) {
        return _failUpload(localId, attempt, 'CHAT_ATTACHMENT_HASH_MISMATCH');
      }
      final workspaceId = _workspaceId()?.trim();
      if (workspaceId == null || !isSafeChatContextIdentifier(workspaceId)) {
        return _failUpload(localId, attempt, 'WORKSPACE_CONTEXT_UNAVAILABLE');
      }
      final privateUri = 'app-private://chat-attachment/$localId';
      final metadata = UploadMetadata(
        sourceScene: 'workspace_attachment',
        fileName: file.displayName,
        mimeType: file.mimeType,
        sizeBytes: actualSize,
        durationSeconds: 0,
        appPrivateUri: privateUri,
        sha256: digest,
        workspaceId: workspaceId,
      );
      final uploader = UploadClient(
        apiClient: _apiClient,
        objectTransport:
            _objectUploadTransport ??
            HttpObjectUploadTransport(
              openRead: (uri) {
                if (uri != privateUri) {
                  return Stream<List<int>>.error(
                    StateError('CHAT_ATTACHMENT_PRIVATE_REF_INVALID'),
                  );
                }
                return source.openRead();
              },
            ),
      );
      final token = await uploader.requestUploadToken(
        metadata: metadata,
        idempotencyKey: 'chat-file-token-$localId-$attempt',
      );
      if (!_isCurrentAttempt(localId, attempt)) return;
      if (!token.ok || token.value == null) {
        return _failUpload(
          localId,
          attempt,
          token.error?.code ?? 'CHAT_ATTACHMENT_UPLOAD_TOKEN_FAILED',
        );
      }
      final uploaded = await uploader.uploadToObjectStore(
        token: token.value!,
        metadata: metadata,
      );
      if (!_isCurrentAttempt(localId, attempt)) return;
      if (!uploaded.ok) {
        return _failUpload(
          localId,
          attempt,
          uploaded.error?.code ?? 'CHAT_ATTACHMENT_UPLOAD_FAILED',
        );
      }
      final completed = await uploader.completeUpload(
        uploadId: token.value!.uploadId,
        metadata: metadata,
        idempotencyKey: 'chat-file-complete-$localId-$attempt',
      );
      if (!_isCurrentAttempt(localId, attempt)) return;
      final resource = completed.value;
      if (!completed.ok ||
          resource == null ||
          !isSafeChatContextIdentifier(resource.resourceId)) {
        return _failUpload(
          localId,
          attempt,
          completed.error?.code ?? 'CHAT_ATTACHMENT_UPLOAD_COMPLETE_FAILED',
        );
      }
      if (!_isCurrentAttempt(localId, attempt)) return;
      _replace(
        localId,
        _find(localId).copyWith(
          status: ChatFileAttachmentStatus.ready,
          resourceId: resource.resourceId,
          clearError: true,
        ),
      );
      _notifyListenersIfActive();
    } on Object {
      _failUpload(localId, attempt, 'CHAT_ATTACHMENT_UPLOAD_FAILED');
    }
  }

  void _failUpload(String localId, int attempt, String code) {
    if (!_isCurrentAttempt(localId, attempt)) return;
    _replace(
      localId,
      _find(localId).copyWith(
        status: ChatFileAttachmentStatus.failed,
        clearResourceId: true,
        errorCode: code,
      ),
    );
    _notifyListenersIfActive();
  }

  bool _isCurrentAttempt(String localId, int attempt) =>
      !_disposed &&
      _attemptByLocalId[localId] == attempt &&
      _attachments.any((attachment) => attachment.localId == localId);

  void _notifyListenersIfActive() {
    if (!_disposed) notifyListeners();
  }

  ChatFileAttachment _find(String localId) =>
      _attachments.firstWhere((attachment) => attachment.localId == localId);

  void _replace(String localId, ChatFileAttachment replacement) {
    final index = _attachments.indexWhere(
      (attachment) => attachment.localId == localId,
    );
    if (index >= 0) _attachments[index] = replacement;
  }

  String _nextLocalId(_PickedChatAttachment file) {
    _sequence += 1;
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '${file.pickerRef}:${file.displayName}:${file.sizeBytes}:$_sequence',
          ),
        )
        .toString()
        .substring(0, 24);
    return 'chatfile-$fingerprint';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

final class _PickedChatAttachment {
  const _PickedChatAttachment({
    required this.pickerRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sourcePath,
    required this.kind,
    this.contentHash,
  });

  factory _PickedChatAttachment.fromDocument(PickedDocumentFile file) =>
      _PickedChatAttachment(
        pickerRef: file.pickerRef,
        displayName: file.displayName,
        mimeType: file.mimeType,
        sizeBytes: file.sizeBytes,
        sourcePath: file.sourcePath ?? '',
        kind: ChatFileAttachmentKind.file,
        contentHash: file.contentHash,
      );

  factory _PickedChatAttachment.fromImage(PickedMediaFile file) =>
      _PickedChatAttachment(
        pickerRef: file.pickerRef,
        displayName: file.displayName,
        mimeType: file.mimeType,
        sizeBytes: file.sizeBytes,
        sourcePath: file.sourcePath ?? '',
        kind: ChatFileAttachmentKind.image,
      );

  factory _PickedChatAttachment.fromVideo(PickedMediaFile file) =>
      _PickedChatAttachment(
        pickerRef: file.pickerRef,
        displayName: file.displayName,
        mimeType: file.mimeType,
        sizeBytes: file.sizeBytes,
        sourcePath: file.sourcePath ?? '',
        kind: ChatFileAttachmentKind.video,
      );

  final String pickerRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final String sourcePath;
  final ChatFileAttachmentKind kind;
  final String? contentHash;
}

AppFailure _failure(String code) => AppFailure(
  code: code,
  category: AppFailureCategory.storage,
  message: 'Chat file attachment operation failed',
  userMessageKey: 'error.chat.attachment',
  isRetryable: true,
  recoveryActions: const <String>['retry'],
);
