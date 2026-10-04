import 'package:huahuo_api/huahuo_api.dart';
import '../../../core/native/voice_recorder_port.dart';

final class ChatVoiceUploadResult<T> {
  const ChatVoiceUploadResult._({required this.ok, this.value, this.error});

  factory ChatVoiceUploadResult.success(T value) {
    return ChatVoiceUploadResult<T>._(ok: true, value: value);
  }

  factory ChatVoiceUploadResult.failure(AppFailure error) {
    return ChatVoiceUploadResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

abstract interface class ChatVoiceUploadPort {
  Future<ChatVoiceUploadResult<ResourceIndex>> uploadVoice(
    VoiceRecordingDraft draft,
  );
}

final class ChatVoiceUploader implements ChatVoiceUploadPort {
  const ChatVoiceUploader({required UploadClient uploadClient})
    : _uploadClient = uploadClient;

  final UploadClient _uploadClient;

  @override
  Future<ChatVoiceUploadResult<ResourceIndex>> uploadVoice(
    VoiceRecordingDraft draft,
  ) async {
    final metadata = UploadMetadata(
      sourceScene: 'workspace_voice',
      fileName: draft.fileName,
      mimeType: draft.mimeType,
      sizeBytes: draft.sizeBytes,
      durationSeconds: draft.durationSeconds,
      appPrivateUri: draft.appPrivateUri,
      sha256: draft.sha256,
    );
    final token = await _uploadClient.requestUploadToken(
      metadata: metadata,
      idempotencyKey: _keyFor(draft.recordingId, 'token'),
    );
    if (!token.ok || token.value == null) {
      return ChatVoiceUploadResult<ResourceIndex>.failure(
        token.error ?? uploadFailure('CHAT_VOICE_UPLOAD_TOKEN_FAILED'),
      );
    }
    final object = await _uploadClient.uploadToObjectStore(
      token: token.value!,
      metadata: metadata,
    );
    if (!object.ok) {
      return ChatVoiceUploadResult<ResourceIndex>.failure(
        object.error ?? uploadFailure('CHAT_VOICE_OBJECT_UPLOAD_FAILED'),
      );
    }
    final completed = await _uploadClient.completeUpload(
      uploadId: token.value!.uploadId,
      metadata: metadata,
      idempotencyKey: _keyFor(draft.recordingId, 'complete'),
    );
    if (!completed.ok || completed.value == null) {
      return ChatVoiceUploadResult<ResourceIndex>.failure(
        completed.error ?? uploadFailure('CHAT_VOICE_UPLOAD_COMPLETE_FAILED'),
      );
    }
    return ChatVoiceUploadResult<ResourceIndex>.success(completed.value!);
  }
}

String _keyFor(String recordingId, String operation) {
  return 'idem-workspace-voice-$operation-$recordingId';
}
