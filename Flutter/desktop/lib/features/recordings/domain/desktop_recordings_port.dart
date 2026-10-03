import '../../../shared/services/desktop_service_result.dart';

enum DesktopRecordingUploadStage {
  hashing,
  requestingUpload,
  uploadingObject,
  completingUpload,
  creatingRecording,
}

final class DesktopLocalAudioRequest {
  const DesktopLocalAudioRequest({
    required this.filePath,
    required this.fileName,
    required this.mimeType,
    required this.workspaceId,
    this.title,
  });

  final String filePath;
  final String fileName;
  final String mimeType;
  final String workspaceId;
  final String? title;
}

final class DesktopRecordingSubmission {
  const DesktopRecordingSubmission({
    required this.recordingId,
    required this.title,
    required this.status,
    this.asrTaskId,
  });

  final String recordingId;
  final String title;
  final String status;
  final String? asrTaskId;
}

final class DesktopRecordingProgress {
  const DesktopRecordingProgress({
    required this.recordingId,
    required this.status,
    this.progress,
    this.message,
  });

  final String recordingId;
  final String status;
  final int? progress;
  final String? message;

  bool get isTerminal => const <String>{
    'succeeded',
    'completed',
    'failed',
    'timeout',
    'cancelled',
  }.contains(status);
}

typedef DesktopRecordingUploadStageListener =
    void Function(DesktopRecordingUploadStage stage);

abstract interface class DesktopRecordingsPort {
  Future<DesktopServiceResult<DesktopRecordingSubmission>> submitLocalAudio(
    DesktopLocalAudioRequest request, {
    DesktopRecordingUploadStageListener? onStage,
  });

  Future<DesktopServiceResult<DesktopRecordingProgress>> loadProgress(
    String recordingId,
  );
}

final class UnavailableDesktopRecordingsPort implements DesktopRecordingsPort {
  const UnavailableDesktopRecordingsPort();

  @override
  Future<DesktopServiceResult<DesktopRecordingProgress>> loadProgress(
    String recordingId,
  ) async => const DesktopServiceResult<DesktopRecordingProgress>.unavailable(
    code: 'DESKTOP_RECORDING_UNAVAILABLE',
    message: '桌面端录音转写服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<DesktopRecordingSubmission>> submitLocalAudio(
    DesktopLocalAudioRequest request, {
    DesktopRecordingUploadStageListener? onStage,
  }) async =>
      const DesktopServiceResult<DesktopRecordingSubmission>.unavailable(
        code: 'DESKTOP_RECORDING_UNAVAILABLE',
        message: '桌面端录音转写服务暂不可用',
      );
}
