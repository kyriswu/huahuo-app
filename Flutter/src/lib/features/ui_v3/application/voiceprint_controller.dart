import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/native/voice_recorder_port.dart';
import '../data/voiceprint_api.dart';
import '../data/voiceprint_profile_repository.dart';
import '../domain/voiceprint_profile.dart';

const voiceprintEnrollmentText = '你好，无限花火。这是我的声音样本，请在今后的语音转写中识别并标记我的发言。';
const voiceprintMinimumSeconds = voiceprintWavMinimumSeconds;
const voiceprintMaximumSeconds = voiceprintWavMaximumSeconds;
const voiceprintMaximumAcceptedDraftSeconds =
    voiceprintWavMaximumReportedSeconds;

final class VoiceprintEnrollment {
  const VoiceprintEnrollment({
    required this.userId,
    required this.profileId,
    required this.speakerNick,
    required this.referenceVersion,
    required this.enrolledAt,
    required this.isDemo,
  });

  final String userId;
  final String profileId;
  final String speakerNick;
  final int referenceVersion;
  final DateTime enrolledAt;
  final bool isDemo;
}

final class VoiceprintPortResult<T> {
  const VoiceprintPortResult._({required this.ok, this.value, this.errorCode});

  factory VoiceprintPortResult.success(T value) =>
      VoiceprintPortResult<T>._(ok: true, value: value);

  factory VoiceprintPortResult.failure(String errorCode) =>
      VoiceprintPortResult<T>._(ok: false, errorCode: errorCode);

  final bool ok;
  final T? value;
  final String? errorCode;
}

abstract interface class VoiceprintPort {
  VoiceprintEnrollment? beginSession(String? userId);

  Future<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> listProfiles({
    required String userId,
  });

  Future<VoiceprintPortResult<VoiceprintEnrollment>> enroll({
    required String userId,
    required String profileId,
    required String profileName,
    required VoiceRecordingDraft sample,
    required bool consentAccepted,
    String? replacementProfileId,
  });

  Future<VoiceprintPortResult<bool>> deleteEnrollment({
    required String userId,
    required String profileId,
  });

  Future<VoiceprintPortResult<bool>> discardSample(String appPrivateUri);
}

typedef DeleteVoiceprintSample = Future<bool> Function(String appPrivateUri);

final class RemoteVoiceprintPort implements VoiceprintPort {
  RemoteVoiceprintPort({
    required VoiceprintApiPort api,
    required DeleteVoiceprintSample deleteLocalSample,
    DateTime Function()? now,
  }) : _api = api,
       _deleteLocalSample = deleteLocalSample,
       _now = now ?? DateTime.now;

  final VoiceprintApiPort _api;
  final DeleteVoiceprintSample _deleteLocalSample;
  final DateTime Function() _now;
  String? _sessionScope;
  VoiceprintEnrollment? _enrollment;
  int _deleteCounter = 0;
  final Map<String, String> _deleteIdempotencyKeys = <String, String>{};

  @override
  VoiceprintEnrollment? beginSession(String? userId) {
    if (userId != _sessionScope) {
      _sessionScope = userId;
      _enrollment = null;
      _deleteIdempotencyKeys.clear();
    }
    return _enrollment;
  }

  @override
  Future<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> listProfiles({
    required String userId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    final result = await _api.listProfiles();
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    final profiles = result.value;
    if (!result.ok || profiles == null) {
      return VoiceprintPortResult.failure(
        result.errorCode ?? 'VOICEPRINT_LIST_FAILED',
      );
    }
    return VoiceprintPortResult.success(profiles);
  }

  @override
  Future<VoiceprintPortResult<VoiceprintEnrollment>> enroll({
    required String userId,
    required String profileId,
    required String profileName,
    required VoiceRecordingDraft sample,
    required bool consentAccepted,
    String? replacementProfileId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    if (!consentAccepted) {
      return VoiceprintPortResult.failure('VOICEPRINT_CONSENT_REQUIRED');
    }
    final result = await _api.enroll(
      VoiceprintEnrollRequest(
        sample: sample,
        profileId: profileId,
        speakerNick: profileName,
        consentVersion: voiceprintConsentVersion,
        idempotencyKey: _enrollIdempotencyKey(
          userId: userId,
          profileId: profileId,
          sample: sample,
        ),
        replacementProfileId: replacementProfileId,
      ),
    );
    final remote = result.value;
    if (!result.ok || remote == null) {
      return VoiceprintPortResult.failure(
        result.errorCode ?? 'VOICEPRINT_ENROLL_FAILED',
      );
    }
    if (!await _deleteLocalSample(sample.appPrivateUri)) {
      return VoiceprintPortResult.failure('VOICEPRINT_SAMPLE_DELETE_FAILED');
    }
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    _enrollment = VoiceprintEnrollment(
      userId: userId,
      profileId: remote.profileId,
      speakerNick: remote.speakerNick,
      referenceVersion: remote.referenceVersion,
      enrolledAt: remote.registeredAt,
      isDemo: false,
    );
    return VoiceprintPortResult.success(_enrollment!);
  }

  @override
  Future<VoiceprintPortResult<bool>> deleteEnrollment({
    required String userId,
    required String profileId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    final operationScope = '$userId\n$profileId';
    final idempotencyKey = _deleteIdempotencyKeys.putIfAbsent(operationScope, () {
      final operationSeed =
          '$operationScope\n${_now().toUtc().microsecondsSinceEpoch}\n${_deleteCounter++}';
      return 'vpdel-${sha256.convert(utf8.encode(operationSeed))}';
    });
    final result = await _api.deleteProfile(
      VoiceprintDeleteRequest(
        profileId: profileId,
        idempotencyKey: idempotencyKey,
      ),
    );
    if (result.ok || result.error?.isRetryable != true) {
      _deleteIdempotencyKeys.remove(operationScope);
    }
    if (!result.ok || result.value == null) {
      return VoiceprintPortResult.failure(
        result.errorCode ?? 'VOICEPRINT_DELETE_FAILED',
      );
    }
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    if (_enrollment?.profileId == profileId) _enrollment = null;
    return VoiceprintPortResult.success(true);
  }

  @override
  Future<VoiceprintPortResult<bool>> discardSample(String appPrivateUri) async {
    final deleted = await _deleteLocalSample(appPrivateUri);
    return deleted
        ? VoiceprintPortResult.success(true)
        : VoiceprintPortResult.failure('VOICEPRINT_SAMPLE_DELETE_FAILED');
  }
}

final class SessionMockVoiceprintPort implements VoiceprintPort {
  SessionMockVoiceprintPort({
    required DeleteVoiceprintSample deleteLocalSample,
    DateTime Function()? now,
  }) : _deleteLocalSample = deleteLocalSample,
       _now = now ?? DateTime.now;

  final DeleteVoiceprintSample _deleteLocalSample;
  final DateTime Function() _now;
  String? _sessionScope;
  VoiceprintEnrollment? _enrollment;

  @override
  VoiceprintEnrollment? beginSession(String? userId) {
    if (userId != _sessionScope) {
      _sessionScope = userId;
      _enrollment = null;
    }
    return _enrollment;
  }

  @override
  Future<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> listProfiles({
    required String userId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    return VoiceprintPortResult.success(const <VoiceprintRemoteProfile>[]);
  }

  @override
  Future<VoiceprintPortResult<VoiceprintEnrollment>> enroll({
    required String userId,
    required String profileId,
    required String profileName,
    required VoiceRecordingDraft sample,
    required bool consentAccepted,
    String? replacementProfileId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    if (!consentAccepted) {
      return VoiceprintPortResult.failure('VOICEPRINT_CONSENT_REQUIRED');
    }
    if (sample.durationSeconds < voiceprintMinimumSeconds ||
        sample.durationSeconds > voiceprintMaximumAcceptedDraftSeconds) {
      return VoiceprintPortResult.failure('VOICEPRINT_SAMPLE_DURATION_INVALID');
    }
    if (!await _deleteLocalSample(sample.appPrivateUri)) {
      return VoiceprintPortResult.failure('VOICEPRINT_SAMPLE_DELETE_FAILED');
    }
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    _enrollment = VoiceprintEnrollment(
      userId: userId,
      profileId: profileId,
      speakerNick: profileName,
      referenceVersion: 1,
      enrolledAt: _now(),
      isDemo: true,
    );
    return VoiceprintPortResult.success(_enrollment!);
  }

  @override
  Future<VoiceprintPortResult<bool>> deleteEnrollment({
    required String userId,
    required String profileId,
  }) async {
    if (_sessionScope == null || userId != _sessionScope) {
      return VoiceprintPortResult.failure('VOICEPRINT_LOGIN_REQUIRED');
    }
    if (_enrollment?.profileId == profileId) _enrollment = null;
    return VoiceprintPortResult.success(true);
  }

  @override
  Future<VoiceprintPortResult<bool>> discardSample(String appPrivateUri) async {
    final deleted = await _deleteLocalSample(appPrivateUri);
    return deleted
        ? VoiceprintPortResult.success(true)
        : VoiceprintPortResult.failure('VOICEPRINT_SAMPLE_DELETE_FAILED');
  }
}

enum VoiceprintStatus {
  idle,
  checkingPermission,
  starting,
  recording,
  stopping,
  ready,
  submitting,
  enrolled,
  deleting,
  failed,
}

final class VoiceprintState {
  const VoiceprintState({
    required this.status,
    required this.waveformLevels,
    this.profiles = const <VoiceprintProfile>[],
    this.elapsedSeconds = 0,
    this.consentAccepted = false,
    this.draft,
    this.enrollment,
    this.pendingProfileName,
    this.targetProfileId,
    this.errorCode,
  });

  factory VoiceprintState.initial({
    VoiceprintEnrollment? enrollment,
    List<VoiceprintProfile> profiles = const <VoiceprintProfile>[],
  }) {
    return VoiceprintState(
      status: enrollment == null && profiles.isEmpty
          ? VoiceprintStatus.idle
          : VoiceprintStatus.enrolled,
      waveformLevels: List<double>.filled(68, 0),
      enrollment: enrollment,
      profiles: List<VoiceprintProfile>.unmodifiable(profiles),
    );
  }

  final VoiceprintStatus status;
  final List<VoiceprintProfile> profiles;
  final int elapsedSeconds;
  final List<double> waveformLevels;
  final bool consentAccepted;
  final VoiceRecordingDraft? draft;
  final VoiceprintEnrollment? enrollment;
  final String? pendingProfileName;
  final String? targetProfileId;
  final String? errorCode;

  bool get isCaptureActive => status == VoiceprintStatus.recording;
  bool get isBusy =>
      status == VoiceprintStatus.checkingPermission ||
      status == VoiceprintStatus.starting ||
      status == VoiceprintStatus.stopping ||
      status == VoiceprintStatus.submitting ||
      status == VoiceprintStatus.deleting;
  bool get canStop =>
      status == VoiceprintStatus.recording &&
      elapsedSeconds >= voiceprintMinimumSeconds;
  bool get canSubmit =>
      status == VoiceprintStatus.ready && draft != null && consentAccepted;

  VoiceprintState copyWith({
    VoiceprintStatus? status,
    int? elapsedSeconds,
    List<double>? waveformLevels,
    List<VoiceprintProfile>? profiles,
    bool? consentAccepted,
    VoiceRecordingDraft? draft,
    VoiceprintEnrollment? enrollment,
    String? pendingProfileName,
    String? targetProfileId,
    String? errorCode,
    bool clearDraft = false,
    bool clearEnrollment = false,
    bool clearPendingProfile = false,
    bool clearTargetProfile = false,
    bool clearError = false,
  }) {
    return VoiceprintState(
      status: status ?? this.status,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      waveformLevels: List<double>.unmodifiable(
        waveformLevels ?? this.waveformLevels,
      ),
      profiles: List<VoiceprintProfile>.unmodifiable(profiles ?? this.profiles),
      consentAccepted: consentAccepted ?? this.consentAccepted,
      draft: clearDraft ? null : draft ?? this.draft,
      enrollment: clearEnrollment ? null : enrollment ?? this.enrollment,
      pendingProfileName: clearPendingProfile
          ? null
          : pendingProfileName ?? this.pendingProfileName,
      targetProfileId: clearTargetProfile
          ? null
          : targetProfileId ?? this.targetProfileId,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

final class VoiceprintController extends ChangeNotifier {
  VoiceprintController({
    required VoiceRecorderPort recorder,
    required VoiceprintPort port,
    required String? initialUserId,
    VoiceprintProfileRepository? profileRepository,
    VoiceprintProfileSyncService? profileSyncService,
    DateTime Function()? now,
  }) : _recorder = recorder,
       _port = port,
       _profileRepository = profileRepository,
       _profileSyncService = profileSyncService,
       _now = now ?? DateTime.now,
       _userId = initialUserId,
       _state = VoiceprintState.initial(
         enrollment: port.beginSession(initialUserId),
         profiles: _loadProfiles(profileRepository, initialUserId),
       );

  final VoiceRecorderPort _recorder;
  final VoiceprintPort _port;
  final VoiceprintProfileRepository? _profileRepository;
  final VoiceprintProfileSyncService? _profileSyncService;
  final DateTime Function() _now;
  String? _userId;
  VoiceprintState _state;
  Timer? _timer;
  StreamSubscription<VoiceLevelSample>? _levelSubscription;
  bool _refreshing = false;
  bool _autoStopQueued = false;
  bool _abandoning = false;
  bool _disposed = false;
  int _sessionRevision = 0;
  String? _captureRecordingId;
  Future<VoiceprintPortResult<VoiceprintEnrollment>>? _pendingEnrollment;
  int _profileCounter = 0;
  Future<bool>? _profileSyncFuture;
  int? _profileSyncFutureRevision;

  VoiceprintState get state => _state;

  Future<void> syncSession(String? userId) async {
    if (userId == _userId || _disposed) return;
    _sessionRevision += 1;
    await _cleanupCaptureAndDraft();
    if (_disposed) return;
    _userId = userId;
    _set(
      VoiceprintState.initial(
        enrollment: _port.beginSession(userId),
        profiles: _loadProfiles(_profileRepository, userId),
      ),
    );
    if (userId != null) await refreshProfiles();
  }

  Future<bool> refreshProfiles() {
    final userId = _userId;
    final revision = _sessionRevision;
    if (_disposed || userId == null) return Future<bool>.value(false);
    final active = _profileSyncFuture;
    if (active != null && _profileSyncFutureRevision == revision) return active;

    late final Future<bool> operation;
    operation = _refreshProfilesForSession(
      userId: userId,
      sessionRevision: revision,
    );
    _profileSyncFuture = operation;
    _profileSyncFutureRevision = revision;
    unawaited(
      operation.whenComplete(() {
        if (identical(_profileSyncFuture, operation)) {
          _profileSyncFuture = null;
          _profileSyncFutureRevision = null;
        }
      }),
    );
    return operation;
  }

  Future<bool> _refreshProfilesForSession({
    required String userId,
    required int sessionRevision,
  }) async {
    final repository = _profileRepository;
    if (repository == null || repository.userScope != userId) return false;
    try {
      final sharedSync = _profileSyncService;
      late final List<VoiceprintProfile> reconciled;
      if (sharedSync != null) {
        final syncMutationEpoch = sharedSync.mutationEpoch;
        final synced = await sharedSync.sync();
        if (_disposed ||
            sessionRevision != _sessionRevision ||
            userId != _userId) {
          return false;
        }
        if (!synced) {
          if (sharedSync.hasActiveMutation ||
              sharedSync.mutationEpoch != syncMutationEpoch) {
            return false;
          }
          _publishProfileSyncFailure();
          return false;
        }
        reconciled = repository.loadProfiles();
      } else {
        final result = await _port.listProfiles(userId: userId);
        if (_disposed ||
            sessionRevision != _sessionRevision ||
            userId != _userId) {
          return false;
        }
        final remoteProfiles = result.value;
        if (!result.ok || remoteProfiles == null) {
          _publishProfileSyncFailure();
          return false;
        }
        reconciled = repository.reconcileRemoteProfiles(
          projectRemoteVoiceprintProfiles(
            localProfiles: repository.loadProfiles(),
            remoteProfiles: remoteProfiles,
          ),
        );
      }
      if (_disposed ||
          sessionRevision != _sessionRevision ||
          userId != _userId) {
        return false;
      }
      final status = switch (_state.status) {
        VoiceprintStatus.idle || VoiceprintStatus.enrolled =>
          reconciled.isEmpty
              ? VoiceprintStatus.idle
              : VoiceprintStatus.enrolled,
        VoiceprintStatus.failed
            when _state.errorCode == 'VOICEPRINT_PROFILE_SYNC_FAILED' =>
          reconciled.isEmpty
              ? VoiceprintStatus.idle
              : VoiceprintStatus.enrolled,
        _ => _state.status,
      };
      _set(
        _state.copyWith(
          status: status,
          profiles: reconciled,
          clearError: _state.errorCode == 'VOICEPRINT_PROFILE_SYNC_FAILED',
        ),
      );
      return true;
    } catch (_) {
      if (_disposed ||
          sessionRevision != _sessionRevision ||
          userId != _userId) {
        return false;
      }
      _publishProfileSyncFailure();
      return false;
    }
  }

  void _publishProfileSyncFailure() {
    if (_state.errorCode != null &&
        _state.errorCode != 'VOICEPRINT_PROFILE_SYNC_FAILED') {
      return;
    }
    if (_state.status != VoiceprintStatus.idle &&
        _state.status != VoiceprintStatus.enrolled) {
      return;
    }
    _set(_state.copyWith(errorCode: 'VOICEPRINT_PROFILE_SYNC_FAILED'));
  }

  String? profileNameError(String rawName, {String? excludingProfileId}) {
    final normalized = normalizeVoiceprintProfileName(rawName);
    if (normalized == null) return '请输入 1-24 个字符的名称';
    final duplicate = _state.profiles.any(
      (profile) =>
          profile.id != excludingProfileId &&
          profile.name.toLowerCase() == normalized.toLowerCase(),
    );
    return duplicate ? '该名称已存在' : null;
  }

  Future<bool> beginProfileEnrollment({
    required String name,
    String? profileId,
  }) async {
    if (_disposed || _abandoning || _state.isBusy || _state.isCaptureActive) {
      return false;
    }
    final error = profileNameError(name, excludingProfileId: profileId);
    if (error != null) {
      _fail(
        error == '该名称已存在'
            ? 'VOICEPRINT_PROFILE_NAME_DUPLICATE'
            : 'VOICEPRINT_PROFILE_NAME_INVALID',
      );
      return false;
    }
    if (profileId != null &&
        !_state.profiles.any((profile) => profile.id == profileId)) {
      _fail('VOICEPRINT_PROFILE_NOT_FOUND');
      return false;
    }
    final targetProfileId = profileId ?? _nextProfileId();
    _set(
      _state.copyWith(
        pendingProfileName: normalizeVoiceprintProfileName(name),
        targetProfileId: targetProfileId,
        clearError: true,
      ),
    );
    final started = await start(replaceExisting: true);
    if (!started && !_disposed) {
      _set(
        _state.copyWith(clearPendingProfile: true, clearTargetProfile: true),
      );
    }
    return started;
  }

  bool renameProfile(String profileId, String rawName) {
    final normalized = normalizeVoiceprintProfileName(rawName);
    if (profileNameError(rawName, excludingProfileId: profileId) != null ||
        normalized == null) {
      _fail(
        normalized == null
            ? 'VOICEPRINT_PROFILE_NAME_INVALID'
            : 'VOICEPRINT_PROFILE_NAME_DUPLICATE',
      );
      return false;
    }
    final profile = _profileForId(profileId);
    final repository = _profileRepository;
    if (profile == null || repository == null) {
      _fail('VOICEPRINT_PROFILE_NOT_FOUND');
      return false;
    }
    try {
      repository.saveProfile(
        profile.copyWith(name: normalized, updatedAt: _now()),
      );
      _set(
        _state.copyWith(
          status: VoiceprintStatus.enrolled,
          profiles: repository.loadProfiles(),
          clearError: true,
        ),
      );
      return true;
    } catch (_) {
      _fail('VOICEPRINT_PROFILE_SAVE_FAILED');
      return false;
    }
  }

  Future<bool> start({bool replaceExisting = false}) async {
    if (_disposed || _abandoning || _state.isBusy || _state.isCaptureActive) {
      return false;
    }
    if (_userId == null) {
      _fail('VOICEPRINT_LOGIN_REQUIRED');
      return false;
    }
    if (_state.enrollment != null && !replaceExisting) {
      _fail('VOICEPRINT_REPLACEMENT_CONFIRMATION_REQUIRED');
      return false;
    }
    final sessionRevision = _sessionRevision;
    _set(
      _state.copyWith(
        status: VoiceprintStatus.checkingPermission,
        clearError: true,
      ),
    );
    final staleDraft = _state.draft;
    if (staleDraft != null) {
      await _port.discardSample(staleDraft.appPrivateUri);
      if (_disposed || sessionRevision != _sessionRevision) return false;
    }
    final targetProfileId =
        _state.targetProfileId ??
        _state.enrollment?.profileId ??
        _nextProfileId();
    final pendingProfileName = normalizeVoiceprintProfileName(
      _state.pendingProfileName ?? _state.enrollment?.speakerNick ?? '我的声纹',
    );
    _set(
      VoiceprintState(
        status: VoiceprintStatus.checkingPermission,
        waveformLevels: _emptyWaveform(),
        enrollment: _state.enrollment,
        profiles: _state.profiles,
        pendingProfileName: pendingProfileName,
        targetProfileId: targetProfileId,
      ),
    );
    var permission = await _recorder.getMicrophonePermission();
    if (_disposed || sessionRevision != _sessionRevision) return false;
    if (permission.ok &&
        permission.value != null &&
        !permission.value!.granted &&
        permission.value!.canAskAgain) {
      permission = await _recorder.requestMicrophonePermission();
      if (_disposed || sessionRevision != _sessionRevision) return false;
    }
    if (!permission.ok || permission.value == null) {
      _fail(permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE');
      return false;
    }
    if (!permission.value!.granted) {
      _fail(
        permission.value!.state == VoiceRecorderPermissionState.blocked
            ? 'VOICE_RECORDER_PERMISSION_BLOCKED'
            : 'VOICE_RECORDER_PERMISSION_DENIED',
      );
      return false;
    }
    _set(_state.copyWith(status: VoiceprintStatus.starting, clearError: true));
    final started = await _recorder.startRecording(
      scene: VoiceRecordingScene.voiceprint,
    );
    if (_disposed || sessionRevision != _sessionRevision) {
      final recordingId = started.value?.recordingId;
      if (started.ok && recordingId != null) {
        await _recorder.cancelOwnedRecording(
          expectedScene: VoiceRecordingScene.voiceprint,
          expectedRecordingId: recordingId,
        );
      }
      return false;
    }
    if (!started.ok || started.value == null) {
      _fail(started.error?.code ?? 'VOICE_RECORDER_START_FAILED');
      return false;
    }
    _captureRecordingId = started.value!.recordingId;
    _set(
      VoiceprintState(
        status: VoiceprintStatus.recording,
        elapsedSeconds: started.value!.elapsedSeconds,
        waveformLevels: _emptyWaveform(),
        enrollment: _state.enrollment,
        profiles: _state.profiles,
        pendingProfileName: _state.pendingProfileName,
        targetProfileId: _state.targetProfileId,
      ),
    );
    _startLevelSubscription();
    _startTimer();
    return true;
  }

  Future<bool> refresh() async {
    if (_disposed || _refreshing || !_state.isCaptureActive) return false;
    final sessionRevision = _sessionRevision;
    _refreshing = true;
    VoiceRecorderResult<VoiceRecorderSnapshot> result;
    try {
      result = await _recorder.refreshState();
    } catch (_) {
      if (!_disposed &&
          sessionRevision == _sessionRevision &&
          _state.isCaptureActive) {
        _refreshing = false;
        _fail('VOICE_RECORDER_STATE_REFRESH_FAILED');
      }
      return false;
    }
    if (_disposed ||
        sessionRevision != _sessionRevision ||
        !_state.isCaptureActive) {
      return false;
    }
    _refreshing = false;
    if (!result.ok || result.value == null) {
      _fail(result.error?.code ?? 'VOICE_RECORDER_STATE_REFRESH_FAILED');
      return false;
    }
    final snapshot = result.value!;
    if (snapshot.state != VoiceRecorderState.recording ||
        snapshot.session?.scene != VoiceRecordingScene.voiceprint) {
      _fail(snapshot.lastErrorCode ?? 'VOICEPRINT_CAPTURE_STATE_LOST');
      return false;
    }
    final elapsed = snapshot.session!.elapsedSeconds
        .clamp(0, voiceprintMaximumSeconds)
        .toInt();
    _set(_state.copyWith(elapsedSeconds: elapsed, clearError: true));
    if (elapsed >= voiceprintMaximumSeconds && !_autoStopQueued) {
      _autoStopQueued = true;
      unawaited(stop(automatic: true));
    }
    return true;
  }

  Future<bool> stop({bool automatic = false}) async {
    if (!_state.isCaptureActive || _state.status == VoiceprintStatus.stopping) {
      return false;
    }
    if (!automatic && _state.elapsedSeconds < voiceprintMinimumSeconds) {
      _set(_state.copyWith(errorCode: 'VOICEPRINT_SAMPLE_TOO_SHORT'));
      return false;
    }
    final sessionRevision = _sessionRevision;
    _stopTimer();
    _set(
      _state.copyWith(
        status: VoiceprintStatus.stopping,
        waveformLevels: _emptyWaveform(),
        clearError: true,
      ),
    );
    await _stopLevelSubscription();
    if (_disposed || sessionRevision != _sessionRevision) return false;
    VoiceRecorderResult<VoiceRecordingDraft> result;
    try {
      final recordingId = _captureRecordingId;
      if (recordingId == null) {
        _fail('VOICEPRINT_CAPTURE_STATE_LOST');
        return false;
      }
      result = await _recorder.stopOwnedRecording(
        expectedScene: VoiceRecordingScene.voiceprint,
        expectedRecordingId: recordingId,
      );
    } catch (_) {
      if (!_disposed && sessionRevision == _sessionRevision) {
        _fail('VOICE_RECORDER_STOP_FAILED');
      }
      return false;
    }
    if (_disposed || sessionRevision != _sessionRevision) {
      if (result.value != null) {
        await _port.discardSample(result.value!.appPrivateUri);
      }
      return false;
    }
    if (!result.ok || result.value == null) {
      _fail(result.error?.code ?? 'VOICE_RECORDER_STOP_FAILED');
      return false;
    }
    final draft = result.value!;
    _captureRecordingId = null;
    final draftError = _voiceprintDraftError(draft);
    if (draftError != null) {
      await _port.discardSample(draft.appPrivateUri);
      if (!_disposed && sessionRevision == _sessionRevision) _fail(draftError);
      return false;
    }
    _set(
      _state.copyWith(
        status: VoiceprintStatus.ready,
        elapsedSeconds: draft.durationSeconds,
        draft: draft,
        consentAccepted: false,
        waveformLevels: _emptyWaveform(),
        clearError: true,
      ),
    );
    return true;
  }

  void setConsentAccepted(bool accepted) {
    if (_state.status != VoiceprintStatus.ready) return;
    _set(_state.copyWith(consentAccepted: accepted, clearError: accepted));
  }

  Future<bool> submit() async {
    final userId = _userId;
    final draft = _state.draft;
    final targetProfileId = _state.targetProfileId;
    final target = _profileForId(targetProfileId);
    final normalizedName = normalizeVoiceprintProfileName(
      _state.pendingProfileName ?? target?.name ?? '我的声纹',
    );
    if (userId == null ||
        draft == null ||
        targetProfileId == null ||
        normalizedName == null ||
        _state.status != VoiceprintStatus.ready) {
      return false;
    }
    if (!_state.consentAccepted) {
      _set(_state.copyWith(errorCode: 'VOICEPRINT_CONSENT_REQUIRED'));
      return false;
    }
    _set(
      _state.copyWith(status: VoiceprintStatus.submitting, clearError: true),
    );
    final mutation = _profileSyncService?.beginMutation();
    final mutationSessionRevision = _sessionRevision;
    try {
      final pending = _port.enroll(
        userId: userId,
        profileId: targetProfileId,
        profileName: normalizedName,
        sample: draft,
        consentAccepted: true,
        replacementProfileId: target != null && !target.isDemo
            ? target.id
            : null,
      );
      _pendingEnrollment = pending;
      final result = await pending;
      if (_disposed || mutationSessionRevision != _sessionRevision) {
        return result.ok;
      }
      if (!result.ok || result.value == null) {
        _set(
          _state.copyWith(
            status: VoiceprintStatus.ready,
            errorCode: result.errorCode ?? 'VOICEPRINT_ENROLL_FAILED',
          ),
        );
        return false;
      }
      var profiles = _state.profiles;
      final repository = _profileRepository;
      if (repository != null) {
        final enrollment = result.value!;
        final now = _now();
        final profile = VoiceprintProfile(
          id: enrollment.profileId,
          name: normalizedName,
          enrolledAt: enrollment.enrolledAt,
          updatedAt: now,
          isDemo: enrollment.isDemo,
        );
        try {
          if (target != null && target.id != profile.id) {
            repository.replaceProfile(
              existingProfileId: target.id,
              replacement: profile,
            );
          } else {
            repository.saveProfile(profile);
          }
          profiles = repository.loadProfiles();
        } catch (_) {
          _set(
            VoiceprintState(
              status: VoiceprintStatus.failed,
              waveformLevels: _emptyWaveform(),
              profiles: profiles,
              enrollment: result.value,
              errorCode: 'VOICEPRINT_PROFILE_SAVE_FAILED',
            ),
          );
          return false;
        }
      }
      _set(
        VoiceprintState.initial(enrollment: result.value, profiles: profiles),
      );
      return true;
    } catch (_) {
      if (!_disposed && mutationSessionRevision == _sessionRevision) {
        _set(
          _state.copyWith(
            status: VoiceprintStatus.ready,
            errorCode: 'VOICEPRINT_ENROLL_FAILED',
          ),
        );
      }
      return false;
    } finally {
      if (mutationSessionRevision == _sessionRevision) {
        _pendingEnrollment = null;
      }
      _finishProfileMutation(
        mutation,
        userId: userId,
        sessionRevision: mutationSessionRevision,
      );
    }
  }

  Future<bool> discardDraft() async {
    final draft = _state.draft;
    if (draft == null) return false;
    final result = await _port.discardSample(draft.appPrivateUri);
    if (_disposed) return result.ok;
    if (!result.ok) {
      _fail(result.errorCode ?? 'VOICEPRINT_SAMPLE_DELETE_FAILED');
      return false;
    }
    _set(
      VoiceprintState.initial(
        enrollment: _state.enrollment,
        profiles: _state.profiles,
      ),
    );
    return true;
  }

  Future<bool> abandonEnrollment({bool allowPendingSubmission = false}) async {
    if (_disposed ||
        _abandoning ||
        (_state.status == VoiceprintStatus.submitting &&
            !allowPendingSubmission) ||
        _state.status == VoiceprintStatus.deleting) {
      return false;
    }
    _abandoning = true;
    final enrollment = _state.enrollment;
    final profiles = _state.profiles;
    _sessionRevision += 1;
    final revision = _sessionRevision;
    final pending = _pendingEnrollment;
    try {
      _stopTimer();
      await _stopLevelSubscription();
      if (_disposed) return false;
      final needsCancellation =
          _state.isCaptureActive ||
          _state.status == VoiceprintStatus.starting ||
          _state.status == VoiceprintStatus.stopping;
      if (needsCancellation) {
        final cancelled = await _cancelCapture();
        if (_disposed) return cancelled;
        if (!cancelled) {
          _fail('VOICE_RECORDER_CANCEL_FAILED');
          return false;
        }
      }
      final draft = _state.draft;
      if (draft != null) {
        final discarded = await _discardAfterSubmission(draft, pending);
        if (_disposed) return discarded.ok;
        if (!discarded.ok) {
          _fail(discarded.errorCode ?? 'VOICEPRINT_SAMPLE_DELETE_FAILED');
          return false;
        }
      }
      if (_disposed || revision != _sessionRevision) return false;
      _pendingEnrollment = null;
      _set(VoiceprintState.initial(enrollment: enrollment, profiles: profiles));
      return true;
    } finally {
      _abandoning = false;
    }
  }

  Future<bool> deleteProfile(String profileId) async {
    final userId = _userId;
    final profile = _profileForId(profileId);
    final repository = _profileRepository;
    if (userId == null || profile == null || repository == null) return false;
    final mutation = _profileSyncService?.beginMutation();
    final mutationSessionRevision = _sessionRevision;
    try {
      _set(
        _state.copyWith(status: VoiceprintStatus.deleting, clearError: true),
      );
      if (!profile.isDemo) {
        final result = await _port.deleteEnrollment(
          userId: userId,
          profileId: profileId,
        );
        if (_disposed) return result.ok;
        if (!result.ok) {
          _fail(result.errorCode ?? 'VOICEPRINT_DELETE_FAILED');
          return false;
        }
      }
      try {
        repository.deleteProfile(profileId);
        _set(VoiceprintState.initial(profiles: repository.loadProfiles()));
        return true;
      } catch (_) {
        _fail('VOICEPRINT_PROFILE_DELETE_FAILED');
        return false;
      }
    } finally {
      _finishProfileMutation(
        mutation,
        userId: userId,
        sessionRevision: mutationSessionRevision,
      );
    }
  }

  Future<bool> deleteEnrollment() async {
    if (_state.profiles.isNotEmpty) {
      return deleteProfile(_state.profiles.first.id);
    }
    final userId = _userId;
    final enrollment = _state.enrollment;
    if (userId == null || enrollment == null) return false;
    final mutation = _profileSyncService?.beginMutation();
    final mutationSessionRevision = _sessionRevision;
    try {
      _set(
        _state.copyWith(status: VoiceprintStatus.deleting, clearError: true),
      );
      final result = await _port.deleteEnrollment(
        userId: userId,
        profileId: enrollment.profileId,
      );
      if (_disposed) return result.ok;
      if (!result.ok) {
        _fail(result.errorCode ?? 'VOICEPRINT_DELETE_FAILED');
        return false;
      }
      _set(VoiceprintState.initial(profiles: _state.profiles));
      return true;
    } finally {
      _finishProfileMutation(
        mutation,
        userId: userId,
        sessionRevision: mutationSessionRevision,
      );
    }
  }

  void _finishProfileMutation(
    VoiceprintProfileMutationLease? mutation, {
    required String userId,
    required int sessionRevision,
  }) {
    if (mutation == null) return;
    unawaited(
      _reloadProfilesAfterMutation(
        mutation,
        userId: userId,
        sessionRevision: sessionRevision,
      ),
    );
  }

  Future<void> _reloadProfilesAfterMutation(
    VoiceprintProfileMutationLease mutation, {
    required String userId,
    required int sessionRevision,
  }) async {
    final refreshed = await mutation.releaseAndRefresh();
    if (!refreshed ||
        _disposed ||
        userId != _userId ||
        sessionRevision != _sessionRevision) {
      return;
    }
    final repository = _profileRepository;
    if (repository == null || repository.userScope != userId) return;
    try {
      _set(
        _state.copyWith(
          profiles: repository.loadProfiles(),
          clearError: _state.errorCode == 'VOICEPRINT_PROFILE_SYNC_FAILED',
        ),
      );
    } catch (_) {
      // The completed mutation already owns the visible result; a later
      // explicit refresh can retry a transient local read failure.
    }
  }

  VoiceprintProfile? _profileForId(String? profileId) {
    if (profileId == null) return null;
    for (final profile in _state.profiles) {
      if (profile.id == profileId) return profile;
    }
    return null;
  }

  String _nextProfileId() {
    final timestamp = _now().toUtc().microsecondsSinceEpoch;
    return 'voiceprint-$timestamp-${_profileCounter++}';
  }

  Future<void> _cleanupCaptureAndDraft() async {
    _stopTimer();
    await _stopLevelSubscription();
    if (_state.isCaptureActive ||
        _state.status == VoiceprintStatus.starting ||
        _state.status == VoiceprintStatus.stopping) {
      await _cancelCapture();
    }
    final draft = _state.draft;
    if (draft != null) await _discardAfterSubmission(draft, _pendingEnrollment);
  }

  Future<bool> _cancelCapture() async {
    final recordingId = _captureRecordingId;
    if (recordingId == null) return true;
    final result = await _recorder.cancelOwnedRecording(
      expectedScene: VoiceRecordingScene.voiceprint,
      expectedRecordingId: recordingId,
    );
    final released =
        result.ok || result.error?.code == voiceRecorderSessionMismatchCode;
    if (released && _captureRecordingId == recordingId) {
      _captureRecordingId = null;
    }
    return released;
  }

  Future<VoiceprintPortResult<bool>> _discardAfterSubmission(
    VoiceRecordingDraft draft,
    Future<VoiceprintPortResult<VoiceprintEnrollment>>? pending,
  ) async {
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        return _port.discardSample(draft.appPrivateUri);
      }
    }
    return _port.discardSample(draft.appPrivateUri);
  }

  void _startTimer() {
    _stopTimer();
    _autoStopQueued = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refresh());
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _refreshing = false;
  }

  void _startLevelSubscription() {
    unawaited(_stopLevelSubscription());
    _levelSubscription = _recorder.levelSamples.listen((sample) {
      if (_disposed || _state.status != VoiceprintStatus.recording) return;
      final raw = (sample.average * .45 + sample.peak * .55)
          .clamp(0.0, 1.0)
          .toDouble();
      final previous = _state.waveformLevels.isEmpty
          ? 0.0
          : _state.waveformLevels.last;
      final smoothed = (previous * .58 + raw * .42).clamp(0.0, 1.0).toDouble();
      final levels = List<double>.of(_state.waveformLevels);
      if (levels.length >= 68) levels.removeAt(0);
      levels.add(smoothed);
      while (levels.length < 68) {
        levels.insert(0, 0);
      }
      _set(_state.copyWith(waveformLevels: levels));
    });
  }

  Future<void> _stopLevelSubscription() async {
    final subscription = _levelSubscription;
    _levelSubscription = null;
    await subscription?.cancel();
  }

  void _fail(String code) {
    final shouldCancelNative =
        _state.isCaptureActive ||
        _state.status == VoiceprintStatus.starting ||
        _state.status == VoiceprintStatus.stopping;
    _stopTimer();
    unawaited(_stopLevelSubscription());
    if (shouldCancelNative) unawaited(_cancelCapture());
    _set(
      _state.copyWith(
        status: VoiceprintStatus.failed,
        errorCode: code,
        waveformLevels: _emptyWaveform(),
      ),
    );
  }

  void _set(VoiceprintState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTimer();
    final subscription = _levelSubscription;
    _levelSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (_state.isCaptureActive ||
        _state.status == VoiceprintStatus.starting ||
        _state.status == VoiceprintStatus.stopping) {
      unawaited(_cancelCapture());
    }
    final draft = _state.draft;
    if (draft != null) {
      unawaited(_discardAfterSubmission(draft, _pendingEnrollment));
    }
    super.dispose();
  }
}

// resident-provider: Shares one voiceprint port dependency for the full account session.
final voiceprintPortProvider = Provider<VoiceprintPort>((ref) {
  final sessionStore = ref.read(sessionStoreProvider);
  final port = RemoteVoiceprintPort(
    api: ref.watch(voiceprintApiProvider),
    deleteLocalSample: (uri) async {
      final deleted = await ref
          .read(fileStoragePortProvider)
          .deletePrivateAudio(uri);
      return deleted.ok && deleted.value == true;
    },
  );
  String? activeUserId = _voiceprintUserId(sessionStore.state);
  port.beginSession(activeUserId);
  void resetSession() {
    final nextUserId = _voiceprintUserId(sessionStore.state);
    if (nextUserId == activeUserId) return;
    activeUserId = nextUserId;
    port.beginSession(nextUserId);
  }

  sessionStore.addListener(resetSession);
  ref.onDispose(() => sessionStore.removeListener(resetSession));
  return port;
});

final voiceprintControllerProvider =
    ChangeNotifierProvider.autoDispose<VoiceprintController>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final port = ref.read(voiceprintPortProvider);
      final controller = VoiceprintController(
        recorder: ref.read(voiceRecorderPortProvider),
        port: port,
        initialUserId: _voiceprintUserId(sessionStore.state),
        profileRepository: ref.watch(voiceprintProfileRepositoryProvider),
        profileSyncService: port is RemoteVoiceprintPort
            ? ref.read(voiceprintProfileSyncServiceProvider)
            : null,
      );
      void syncSession() {
        unawaited(
          controller.syncSession(_voiceprintUserId(sessionStore.state)),
        );
      }

      sessionStore.addListener(syncSession);
      ref.onDispose(() => sessionStore.removeListener(syncSession));
      unawaited(controller.refreshProfiles());
      return controller;
    });

List<double> _emptyWaveform() => List<double>.filled(68, 0);

List<VoiceprintProfile> _loadProfiles(
  VoiceprintProfileRepository? repository,
  String? userId,
) {
  if (repository == null || userId == null || repository.userScope != userId) {
    return const <VoiceprintProfile>[];
  }
  try {
    return repository.loadProfiles();
  } catch (_) {
    return const <VoiceprintProfile>[];
  }
}

String? _voiceprintUserId(SessionState state) {
  if (state.authState != SessionAuthState.authenticated) return null;
  return state.user?.userId;
}

String _enrollIdempotencyKey({
  required String userId,
  required String profileId,
  required VoiceRecordingDraft sample,
}) {
  final seed = '$userId\n$profileId\n${sample.recordingId}\n${sample.sha256}';
  return 'vpenr-${sha256.convert(utf8.encode(seed))}';
}

String? _voiceprintDraftError(VoiceRecordingDraft draft) {
  if (draft.durationSeconds < voiceprintMinimumSeconds ||
      draft.durationSeconds > voiceprintMaximumAcceptedDraftSeconds) {
    return 'VOICEPRINT_SAMPLE_DURATION_INVALID';
  }
  if (draft.scene != VoiceRecordingScene.voiceprint ||
      draft.mimeType.toLowerCase() != 'audio/wav' ||
      !draft.fileName.toLowerCase().endsWith('.wav') ||
      !draft.appPrivateUri.toLowerCase().endsWith('.wav') ||
      draft.sampleRateHz != voiceprintWavSampleRateHz ||
      draft.bitDepth != voiceprintWavBitDepth ||
      draft.channelCount != voiceprintWavChannelCount) {
    return 'VOICEPRINT_SAMPLE_FORMAT_INVALID';
  }
  if (draft.sizeBytes <= 0 || draft.sizeBytes > voiceprintWavMaximumBytes) {
    return 'VOICEPRINT_SAMPLE_SIZE_INVALID';
  }
  return null;
}
