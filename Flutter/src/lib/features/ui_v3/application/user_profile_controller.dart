import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/api/scoped_read_cache.dart';
import '../../../core/api/upload_client.dart';
import '../../../core/native/native_file_port.dart';
import '../../../core/tasking/task_orchestrator.dart';

enum UserProfileAvatarSource { photoLibrary, camera }

final class UserProfileAvatar {
  const UserProfileAvatar({
    required this.source,
    required this.revision,
    this.avatarResourceId,
    this.playbackUrl,
    this.localPath,
    this.mimeType,
    this.sizeBytes,
    this.sha256,
  });

  final UserProfileAvatarSource source;
  final int revision;
  final String? avatarResourceId;
  final Uri? playbackUrl;
  final String? localPath;
  final String? mimeType;
  final int? sizeBytes;
  final String? sha256;
}

final class UserProfileSnapshot {
  const UserProfileSnapshot({
    required this.userId,
    required this.nickname,
    required this.maskedPhoneNumber,
    required this.authenticated,
    this.avatar,
    this.isDemo = false,
  });

  final String? userId;
  final String nickname;
  final String maskedPhoneNumber;
  final bool authenticated;
  final UserProfileAvatar? avatar;
  final bool isDemo;

  UserProfileSnapshot copyWith({
    String? nickname,
    UserProfileAvatar? avatar,
    bool? isDemo,
  }) {
    return UserProfileSnapshot(
      userId: userId,
      nickname: nickname ?? this.nickname,
      maskedPhoneNumber: maskedPhoneNumber,
      authenticated: authenticated,
      avatar: avatar ?? this.avatar,
      isDemo: isDemo ?? this.isDemo,
    );
  }
}

final class UserProfileResult<T> {
  const UserProfileResult._({required this.ok, this.value, this.errorCode});

  factory UserProfileResult.success(T value) =>
      UserProfileResult<T>._(ok: true, value: value);

  factory UserProfileResult.failure(String errorCode) =>
      UserProfileResult<T>._(ok: false, errorCode: errorCode);

  final bool ok;
  final T? value;
  final String? errorCode;
}

abstract interface class UserProfilePort {
  UserProfileSnapshot beginSession(SessionState session);

  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  );

  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  });
}

/// Optional remote-read capability kept separate so existing local test ports
/// retain the small synchronous session surface.
abstract interface class UserProfileRemoteLoadPort {
  Future<UserProfileResult<UserProfileSnapshot>> load(SessionState session);
}

final class UnavailableUserProfilePort implements UserProfilePort {
  const UnavailableUserProfilePort();

  @override
  UserProfileSnapshot beginSession(SessionState session) {
    final user = session.user;
    final userId = session.authState == SessionAuthState.authenticated
        ? user?.userId
        : null;
    return UserProfileSnapshot(
      userId: userId,
      nickname: _safeNickname(user?.displayName),
      maskedPhoneNumber: _safeMaskedPhone(user?.maskedPhoneNumber),
      authenticated: userId != null,
    );
  }

  @override
  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  ) async => UserProfileResult.failure('USER_PROFILE_BACKEND_UNAVAILABLE');

  @override
  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  }) async => UserProfileResult.failure('USER_PROFILE_BACKEND_UNAVAILABLE');
}

final class RemoteUserProfilePort
    implements UserProfilePort, UserProfileRemoteLoadPort {
  RemoteUserProfilePort({
    required ApiClient apiClient,
    required NativeFilePort nativeFilePort,
    DateTime Function()? now,
    ObjectUploadTransport? objectUploadTransport,
    Future<Directory> Function()? temporaryDirectory,
    TaskOrchestrator? taskOrchestrator,
  }) : _apiClient = apiClient, // ignore: prefer_initializing_formals
       _nativeFilePort = nativeFilePort, // ignore: prefer_initializing_formals
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _objectUploadTransport = objectUploadTransport,
       _taskOrchestrator = taskOrchestrator,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const _maximumAvatarBytes = 2 * 1024 * 1024;
  static const _maximumAvatarSourceBytes = 50 * 1024 * 1024;

  final ApiClient _apiClient;
  final NativeFilePort _nativeFilePort;
  final DateTime Function() _now;
  final ObjectUploadTransport? _objectUploadTransport;
  final TaskOrchestrator? _taskOrchestrator;
  final Future<Directory> Function() _temporaryDirectory;
  SessionState _session = SessionState.anonymous();

  @override
  UserProfileSnapshot beginSession(SessionState session) {
    _session = session;
    return _sessionSnapshot(session);
  }

  @override
  Future<UserProfileResult<UserProfileSnapshot>> load(
    SessionState session,
  ) async {
    _session = session;
    final base = _sessionSnapshot(session);
    if (!base.authenticated) return UserProfileResult.success(base);
    final result = await _apiClient.request<_RemoteProfile>(
      const ApiRequestOptions<_RemoteProfile>(
        endpointId: 'meProfile',
        parseData: _parseRemoteProfile,
      ),
    );
    final profile = result.data;
    if (!result.ok || profile == null) {
      return UserProfileResult.failure('USER_PROFILE_LOAD_FAILED');
    }
    return UserProfileResult.success(await _snapshotFromRemote(base, profile));
  }

  @override
  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  ) async {
    if (!_sessionSnapshot(_session).authenticated) {
      return UserProfileResult.failure('USER_PROFILE_LOGIN_REQUIRED');
    }
    final picked = await _nativeFilePort.pickMediaFiles(
      kind: NativeMediaKind.image,
      source: source == UserProfileAvatarSource.camera
          ? NativeMediaSource.camera
          : NativeMediaSource.gallery,
    );
    final media = picked.value;
    if (!picked.ok || media == null || media.isEmpty) {
      if (picked.cancelled) {
        return UserProfileResult.failure('USER_PROFILE_AVATAR_PICK_CANCELLED');
      }
      return UserProfileResult.failure(
        picked.error?.code ?? 'USER_PROFILE_AVATAR_PICK_FAILED',
      );
    }
    final prepared = await _prepareAvatar(media.first, source);
    return prepared == null
        ? UserProfileResult.failure('USER_PROFILE_AVATAR_PREPARE_FAILED')
        : UserProfileResult.success(prepared);
  }

  @override
  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  }) async {
    if (!base.authenticated ||
        base.userId != _sessionSnapshot(_session).userId) {
      return UserProfileResult.failure('USER_PROFILE_LOGIN_REQUIRED');
    }
    final displayName = nickname.trim();
    if (!_validNickname(displayName)) {
      return UserProfileResult.failure('USER_PROFILE_NICKNAME_INVALID');
    }
    var avatarResourceId = avatar?.avatarResourceId;
    if (avatar?.localPath != null && avatarResourceId == null) {
      final uploaded = await _uploadAvatar(avatar!);
      if (uploaded == null) {
        return UserProfileResult.failure('USER_PROFILE_AVATAR_UPLOAD_FAILED');
      }
      avatarResourceId = uploaded;
    }
    final result = await _apiClient.request<_RemoteProfile>(
      ApiRequestOptions<_RemoteProfile>(
        endpointId: 'updateMeProfile',
        body: <String, Object?>{
          'displayName': displayName,
          if (avatarResourceId != null) 'avatarResourceId': avatarResourceId,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey:
              'profile-save-${base.userId}-${_now().toUtc().microsecondsSinceEpoch}',
        ),
        parseData: _parseRemoteProfile,
      ),
    );
    final profile = result.data;
    if (!result.ok) {
      return UserProfileResult.failure('USER_PROFILE_SAVE_FAILED');
    }
    if (profile == null || !_validNickname(profile.displayName)) {
      return UserProfileResult.failure('USER_PROFILE_SAVE_RESPONSE_INVALID');
    }
    return UserProfileResult.success(await _snapshotFromRemote(base, profile));
  }

  Future<String?> _uploadAvatar(UserProfileAvatar avatar) async {
    final localPath = avatar.localPath;
    final hash = avatar.sha256;
    final size = avatar.sizeBytes;
    if (localPath == null || hash == null || size == null || size <= 0) {
      return null;
    }
    final file = File(localPath);
    if (!await file.exists() || await file.length() != size) return null;
    final metadata = UploadMetadata(
      sourceScene: 'avatar',
      fileName: 'avatar-$hash.jpg',
      mimeType: avatar.mimeType ?? 'image/jpeg',
      sizeBytes: size,
      durationSeconds: 0,
      appPrivateUri: 'app-private://avatar/$hash.jpg',
      sha256: hash,
    );
    final uploader = UploadClient(
      apiClient: _apiClient,
      objectTransport:
          _objectUploadTransport ??
          HttpObjectUploadTransport(
            openRead: (uri) => uri == metadata.appPrivateUri
                ? file.openRead()
                : Stream<List<int>>.error(
                    StateError('USER_PROFILE_AVATAR_PRIVATE_REF_INVALID'),
                  ),
          ),
    );
    final token = await uploader.requestUploadToken(
      metadata: metadata,
      idempotencyKey: 'profile-avatar-token-$hash',
    );
    if (!token.ok || token.value == null) return null;
    final uploaded = await uploader.uploadToObjectStore(
      token: token.value!,
      metadata: metadata,
    );
    if (!uploaded.ok) return null;
    final completed = await uploader.completeUpload(
      uploadId: token.value!.uploadId,
      metadata: metadata,
      idempotencyKey: 'profile-avatar-complete-$hash',
    );
    return completed.ok ? completed.value?.resourceId : null;
  }

  Future<UserProfileAvatar?> _prepareAvatar(
    PickedMediaFile picked,
    UserProfileAvatarSource source,
  ) async {
    final sourcePath = picked.sourcePath?.trim();
    if (sourcePath == null || sourcePath.isEmpty) return null;
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return null;
      final sourceLength = await sourceFile.length();
      if (sourceLength <= 0 || sourceLength > _maximumAvatarSourceBytes) {
        return null;
      }
      final taskKey = _avatarTransformTaskKey(sourcePath, sourceLength);
      final orchestrator = _taskOrchestrator;
      final transformed = orchestrator == null
          ? await _readAndTransformAvatar(sourceFile)
          : await orchestrator.schedule<_PreparedAvatarTransform?>(
              // performance-rfc: profile-avatar-transform
              TaskSpec(
                key: taskKey,
                owner: 'profile-avatar-transform',
                priority: TaskPriority.userBlocking,
                resources: const <TaskResource>{
                  TaskResource.cpu,
                  TaskResource.media,
                },
                foregroundOnly: true,
                deadline: const Duration(seconds: 30),
              ),
              (token) => _readAndTransformAvatar(sourceFile, token),
            );
      if (transformed == null) return null;
      final bytes = transformed.bytes;
      final hash = transformed.sha256;
      final directory = await _temporaryDirectory();
      final file = File('${directory.path}/huahuo-avatar-$hash.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return UserProfileAvatar(
        source: source,
        revision: _now().microsecondsSinceEpoch,
        localPath: file.path,
        mimeType: 'image/jpeg',
        sizeBytes: bytes.length,
        sha256: hash,
      );
    } on Object {
      return null;
    }
  }

  Future<UserProfileSnapshot> _snapshotFromRemote(
    UserProfileSnapshot base,
    _RemoteProfile remote,
  ) async {
    final resourceId = remote.avatarResourceId;
    Uri? playbackUrl;
    if (resourceId != null) {
      final result = await _apiClient.request<Uri>(
        ApiRequestOptions<Uri>(
          endpointId: 'mediaResourcePlayback',
          pathParams: <String, Object>{'resourceId': resourceId},
          parseData: _parsePlaybackUri,
        ),
      );
      playbackUrl = result.data;
    }
    return UserProfileSnapshot(
      userId: base.userId,
      nickname: _safeNickname(remote.displayName),
      maskedPhoneNumber: base.maskedPhoneNumber,
      authenticated: base.authenticated,
      avatar: resourceId == null
          ? null
          : UserProfileAvatar(
              source: UserProfileAvatarSource.photoLibrary,
              revision:
                  remote.updatedAt?.microsecondsSinceEpoch ??
                  _now().microsecondsSinceEpoch,
              avatarResourceId: resourceId,
              playbackUrl: playbackUrl,
            ),
    );
  }
}

typedef _AvatarTransformResult = ({TransferableTypedData bytes, String sha256});
typedef _PreparedAvatarTransform = ({Uint8List bytes, String sha256});

Future<_PreparedAvatarTransform?> _runAvatarTransform(
  TransferableTypedData input, [
  AppTaskCancellationToken? token,
]) async {
  token?.throwIfCancelled();
  final transformed = await Isolate.run(() => _transformAvatar(input));
  token?.throwIfCancelled();
  if (transformed == null) return null;
  return (
    bytes: transformed.bytes.materialize().asUint8List(),
    sha256: transformed.sha256,
  );
}

Future<_PreparedAvatarTransform?> _readAndTransformAvatar(
  File sourceFile, [
  AppTaskCancellationToken? token,
]) async {
  token?.throwIfCancelled();
  final input = TransferableTypedData.fromList(<Uint8List>[
    await sourceFile.readAsBytes(),
  ]);
  token?.throwIfCancelled();
  return _runAvatarTransform(input, token);
}

String _avatarTransformTaskKey(String sourcePath, int sourceLength) {
  final digest = sha256
      .convert(utf8.encode('$sourcePath\u0000$sourceLength'))
      .toString();
  return 'profile:avatar-transform:${digest.substring(0, 20)}';
}

_AvatarTransformResult? _transformAvatar(TransferableTypedData input) {
  final decoded = image.decodeImage(input.materialize().asUint8List());
  if (decoded == null || decoded.width < 1 || decoded.height < 1) return null;
  final longest = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  final resized = longest > 1024
      ? image.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 1024 : null,
          height: decoded.height > decoded.width ? 1024 : null,
        )
      : decoded;
  for (final quality in const <int>[88, 76, 64, 52, 42]) {
    final encoded = image.encodeJpg(resized, quality: quality);
    if (encoded.isEmpty ||
        encoded.length > RemoteUserProfilePort._maximumAvatarBytes) {
      continue;
    }
    final bytes = Uint8List.fromList(encoded);
    return (
      bytes: TransferableTypedData.fromList(<Uint8List>[bytes]),
      sha256: sha256.convert(bytes).toString(),
    );
  }
  return null;
}

final class _RemoteProfile {
  const _RemoteProfile({
    required this.displayName,
    this.avatarResourceId,
    this.updatedAt,
  });

  final String displayName;
  final String? avatarResourceId;
  final DateTime? updatedAt;
}

_RemoteProfile? _parseRemoteProfile(Object? value) {
  final data = asObjectMap(value);
  final raw = data == null ? null : asObjectMap(data['profile']) ?? data;
  if (raw == null) return null;
  final displayName = _remoteProfileDisplayName(raw['displayName']);
  if (displayName == null) return null;
  final avatarResourceId = raw['avatarResourceId'] == null
      ? null
      : _remoteOpaqueId(raw['avatarResourceId']);
  if (raw['avatarResourceId'] != null && avatarResourceId == null) return null;
  return _RemoteProfile(
    displayName: displayName,
    avatarResourceId: avatarResourceId,
    updatedAt: raw['updatedAt'] is String
        ? DateTime.tryParse(raw['updatedAt'] as String)?.toUtc()
        : null,
  );
}

Uri? _parsePlaybackUri(Object? value) {
  final data = asObjectMap(value);
  if (data == null) return null;
  final directUrl = _remoteText(data['playbackUrl'] ?? data['url']);
  final nested = asObjectMap(data['resource']);
  final valueText =
      directUrl ??
      (nested == null
          ? null
          : _remoteText(nested['playbackUrl'] ?? nested['url']));
  final uri = valueText == null ? null : Uri.tryParse(valueText);
  return uri != null && uri.hasScheme ? uri : null;
}

UserProfileSnapshot _sessionSnapshot(SessionState session) {
  final user = session.user;
  final userId = session.authState == SessionAuthState.authenticated
      ? user?.userId
      : null;
  return UserProfileSnapshot(
    userId: userId,
    nickname: _safeNickname(user?.displayName),
    maskedPhoneNumber: _safeMaskedPhone(user?.maskedPhoneNumber),
    authenticated: userId != null,
  );
}

String? _remoteText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _remoteProfileDisplayName(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return value.isEmpty ? '' : null;
  return _validNickname(normalized) ? normalized : null;
}

String? _remoteOpaqueId(Object? value) {
  final normalized = _remoteText(value);
  return normalized != null &&
          RegExp(r'^[A-Za-z0-9._:-]{1,160}$').hasMatch(normalized)
      ? normalized
      : null;
}

UserProfileSnapshot? _profileFromCachePayload(
  UserProfileSnapshot base,
  Map<String, Object?> payload,
) {
  if (!base.authenticated || base.userId == null) return null;
  final rawNickname = payload['nickname'];
  final nickname = rawNickname is String ? rawNickname.trim() : null;
  if (nickname == null || !_validNickname(nickname)) return null;
  final rawResourceId = payload['avatarResourceId'];
  final resourceId = rawResourceId == null
      ? null
      : _remoteOpaqueId(rawResourceId);
  if (rawResourceId != null && resourceId == null) return null;
  final rawRevision = payload['avatarRevision'];
  final revision = rawRevision is int && rawRevision >= 0 ? rawRevision : null;
  if (resourceId != null && revision == null) return null;
  return UserProfileSnapshot(
    userId: base.userId,
    nickname: nickname,
    maskedPhoneNumber: base.maskedPhoneNumber,
    authenticated: base.authenticated,
    avatar: resourceId == null
        ? null
        : UserProfileAvatar(
            source: UserProfileAvatarSource.photoLibrary,
            revision: revision!,
            avatarResourceId: resourceId,
          ),
  );
}

final class SessionMockUserProfilePort implements UserProfilePort {
  SessionMockUserProfilePort({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  String? _sessionScope;
  UserProfileSnapshot? _saved;

  @override
  UserProfileSnapshot beginSession(SessionState session) {
    final user = session.user;
    final scope = session.authState == SessionAuthState.authenticated
        ? user?.userId
        : null;
    if (scope != _sessionScope) {
      _sessionScope = scope;
      _saved = null;
    }
    final seeded = UserProfileSnapshot(
      userId: scope,
      nickname: _safeNickname(user?.displayName),
      maskedPhoneNumber: _safeMaskedPhone(user?.maskedPhoneNumber),
      authenticated: scope != null,
    );
    final saved = _saved;
    if (saved == null || saved.userId != scope) return seeded;
    return UserProfileSnapshot(
      userId: scope,
      nickname: saved.nickname,
      maskedPhoneNumber: seeded.maskedPhoneNumber,
      authenticated: seeded.authenticated,
      avatar: saved.avatar,
      isDemo: true,
    );
  }

  @override
  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  ) async {
    if (_sessionScope == null) {
      return UserProfileResult.failure('USER_PROFILE_LOGIN_REQUIRED');
    }
    return UserProfileResult.success(
      UserProfileAvatar(
        source: source,
        revision: _now().microsecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  }) async {
    if (_sessionScope == null || base.userId != _sessionScope) {
      return UserProfileResult.failure('USER_PROFILE_LOGIN_REQUIRED');
    }
    final normalized = nickname.trim();
    if (!_validNickname(normalized)) {
      return UserProfileResult.failure('USER_PROFILE_NICKNAME_INVALID');
    }
    _saved = base.copyWith(nickname: normalized, avatar: avatar, isDemo: true);
    return UserProfileResult.success(_saved!);
  }
}

enum UserProfileSaveStatus { idle, saving, saved, failed }

final class UserProfileState {
  const UserProfileState({
    required this.profile,
    required this.draftNickname,
    required this.status,
    this.draftAvatar,
    this.errorCode,
  });

  final UserProfileSnapshot profile;
  final String draftNickname;
  final UserProfileAvatar? draftAvatar;
  final UserProfileSaveStatus status;
  final String? errorCode;

  bool get hasUnsavedChanges =>
      draftNickname != profile.nickname || draftAvatar != profile.avatar;

  UserProfileState copyWith({
    UserProfileSnapshot? profile,
    String? draftNickname,
    UserProfileAvatar? draftAvatar,
    UserProfileSaveStatus? status,
    String? errorCode,
    bool clearError = false,
  }) {
    return UserProfileState(
      profile: profile ?? this.profile,
      draftNickname: draftNickname ?? this.draftNickname,
      draftAvatar: draftAvatar ?? this.draftAvatar,
      status: status ?? this.status,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

final class UserProfileController extends ChangeNotifier {
  UserProfileController({
    required UserProfilePort port,
    required SessionState initialSession,
    ScopedReadCache? Function(SessionState session)? cacheForSession,
  }) : _port = port, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _cacheForSession = cacheForSession,
       _session = initialSession,
       _sessionScope = _profileSessionScope(initialSession) {
    final profile = _port.beginSession(initialSession);
    _state = UserProfileState(
      profile: profile,
      draftNickname: profile.nickname,
      draftAvatar: profile.avatar,
      status: UserProfileSaveStatus.idle,
    );
    _loadRemoteProfile(initialSession);
  }

  final UserProfilePort _port;
  final ScopedReadCache? Function(SessionState session)? _cacheForSession;
  SessionState _session;
  String _sessionScope;
  late UserProfileState _state;
  int _sessionGeneration = 0;
  bool _disposed = false;
  bool _avatarPickerInFlight = false;

  UserProfileState get state => _state;

  void syncSession(SessionState session) {
    final nextScope = _profileSessionScope(session);
    _session = session;
    final profile = _port.beginSession(session);
    if (profile.userId == _state.profile.userId &&
        profile.maskedPhoneNumber == _state.profile.maskedPhoneNumber &&
        nextScope == _sessionScope) {
      return;
    }
    _sessionScope = nextScope;
    _sessionGeneration += 1;
    _set(
      UserProfileState(
        profile: profile,
        draftNickname: profile.nickname,
        draftAvatar: profile.avatar,
        status: UserProfileSaveStatus.idle,
      ),
    );
    _loadRemoteProfile(session);
  }

  void _loadRemoteProfile(SessionState session) {
    final generation = _sessionGeneration;
    final userScope = _state.profile.userId;
    if (userScope == null) return;
    final cache = _cacheFor(session);
    final freshEntry = cache?.readFallback('meProfile', 'profile');
    final cachedEntry = freshEntry ?? cache?.read('meProfile', 'profile');
    final cached = cachedEntry == null
        ? null
        : _profileFromCachePayload(_state.profile, cachedEntry.payload);
    if (cachedEntry != null && cached == null) {
      cache?.invalidate('meProfile', 'profile');
    } else if (cached != null) {
      _set(
        UserProfileState(
          profile: cached,
          draftNickname: cached.nickname,
          draftAvatar: cached.avatar,
          status: UserProfileSaveStatus.idle,
        ),
      );
      if (freshEntry != null) return;
    }
    final port = _port;
    if (port is! UserProfileRemoteLoadPort) return;
    final remotePort = port as UserProfileRemoteLoadPort;
    unawaited(() async {
      final result = await remotePort.load(session);
      if (!_isCurrentSessionCommand(generation, userScope)) return;
      final profile = result.value;
      if (!result.ok || profile == null) {
        _set(
          _state.copyWith(
            status: UserProfileSaveStatus.failed,
            errorCode: result.errorCode ?? 'USER_PROFILE_LOAD_FAILED',
          ),
        );
        return;
      }
      _writeCachedProfile(cache, profile);
      _set(
        UserProfileState(
          profile: profile,
          draftNickname: profile.nickname,
          draftAvatar: profile.avatar,
          status: UserProfileSaveStatus.idle,
        ),
      );
    }());
  }

  void updateNickname(String value) {
    _set(
      _state.copyWith(
        draftNickname: value,
        status: UserProfileSaveStatus.idle,
        clearError: true,
      ),
    );
  }

  Future<bool> chooseAvatar(UserProfileAvatarSource source) async {
    if (_avatarPickerInFlight ||
        _state.status == UserProfileSaveStatus.saving) {
      return false;
    }
    final generation = _sessionGeneration;
    final userScope = _state.profile.userId;
    _set(_state.copyWith(status: UserProfileSaveStatus.idle, clearError: true));
    if (!_isCurrentSessionCommand(generation, userScope)) return false;
    _avatarPickerInFlight = true;
    late final UserProfileResult<UserProfileAvatar> result;
    try {
      result = await _port.chooseAvatar(source);
    } finally {
      _avatarPickerInFlight = false;
    }
    if (!_isCurrentSessionCommand(generation, userScope)) return false;
    if (!result.ok || result.value == null) {
      if (result.errorCode == 'USER_PROFILE_AVATAR_PICK_CANCELLED') {
        _set(
          _state.copyWith(status: UserProfileSaveStatus.idle, clearError: true),
        );
        return false;
      }
      _set(
        _state.copyWith(
          status: UserProfileSaveStatus.failed,
          errorCode: result.errorCode ?? 'USER_PROFILE_AVATAR_PICK_FAILED',
        ),
      );
      return false;
    }
    _set(
      _state.copyWith(
        draftAvatar: result.value,
        status: UserProfileSaveStatus.idle,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> save() async {
    if (_state.status == UserProfileSaveStatus.saving) return false;
    final nickname = _state.draftNickname.trim();
    if (!_validNickname(nickname)) {
      _set(
        _state.copyWith(
          status: UserProfileSaveStatus.failed,
          errorCode: 'USER_PROFILE_NICKNAME_INVALID',
        ),
      );
      return false;
    }
    final generation = _sessionGeneration;
    final userScope = _state.profile.userId;
    final base = _state.profile;
    final avatar = _state.draftAvatar;
    final cache = _cacheFor(_session);
    cache?.invalidate('meProfile', 'profile');
    _set(
      _state.copyWith(status: UserProfileSaveStatus.saving, clearError: true),
    );
    if (!_isCurrentSessionCommand(generation, userScope)) return false;
    final result = await _port.save(
      base: base,
      nickname: nickname,
      avatar: avatar,
    );
    if (!_isCurrentSessionCommand(generation, userScope)) return false;
    if (!result.ok || result.value == null) {
      _set(
        _state.copyWith(
          status: UserProfileSaveStatus.failed,
          errorCode: result.errorCode ?? 'USER_PROFILE_SAVE_FAILED',
        ),
      );
      return false;
    }
    _writeCachedProfile(cache, result.value!);
    _set(
      UserProfileState(
        profile: result.value!,
        draftNickname: result.value!.nickname,
        draftAvatar: result.value!.avatar,
        status: UserProfileSaveStatus.saved,
      ),
    );
    return true;
  }

  void _set(UserProfileState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  bool _isCurrentSessionCommand(int generation, String? userScope) {
    return !_disposed &&
        generation == _sessionGeneration &&
        userScope == _state.profile.userId;
  }

  ScopedReadCache? _cacheFor(SessionState session) {
    try {
      return _cacheForSession?.call(session);
    } on Object {
      return null;
    }
  }

  void _writeCachedProfile(
    ScopedReadCache? cache,
    UserProfileSnapshot profile,
  ) {
    if (cache == null || !profile.authenticated || profile.userId == null) {
      return;
    }
    final avatar = profile.avatar;
    final resourceId = avatar?.avatarResourceId;
    try {
      cache.write(
        'meProfile',
        'profile',
        etag: null,
        payload: <String, Object?>{
          'nickname': profile.nickname,
          if (resourceId != null) 'avatarResourceId': resourceId,
          if (resourceId != null) 'avatarRevision': avatar!.revision,
        },
      );
    } on Object {
      // A local cache failure must not turn a successful profile save into UI
      // failure.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration += 1;
    super.dispose();
  }
}

// resident-provider: Shares one user profile port dependency for the full account session.
final userProfilePortProvider = Provider<UserProfilePort>((ref) {
  try {
    return RemoteUserProfilePort(
      apiClient: ref.watch(apiClientProvider),
      nativeFilePort: ref.watch(nativeFilePortProvider),
      taskOrchestrator: ref.watch(taskOrchestratorProvider),
    );
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return const UnavailableUserProfilePort();
    }
    rethrow;
  }
});

// resident-provider: Preserves the user profile controller state machine across route transitions.
final userProfileControllerProvider =
    ChangeNotifierProvider<UserProfileController>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final controller = UserProfileController(
        port: ref.read(userProfilePortProvider),
        initialSession: sessionStore.state,
        cacheForSession: (session) {
          final userId = session.user?.userId.trim();
          if (session.authState != SessionAuthState.authenticated ||
              userId == null ||
              userId.isEmpty) {
            return null;
          }
          final workspaceScope =
              session.workspace?.workspaceId?.trim().isNotEmpty == true
              ? session.workspace!.workspaceId!.trim()
              : 'profile-global';
          return ScopedReadCache(
            dao: ref.read(appPreferencesDaoProvider),
            userScope: userId,
            workspaceScope: workspaceScope,
            fallbackTtl: ref.read(appCachePolicyProvider).cacheTtl,
          );
        },
      );
      void syncSession() => controller.syncSession(sessionStore.state);
      sessionStore.addListener(syncSession);
      ref.onDispose(() => sessionStore.removeListener(syncSession));
      return controller;
    });

bool _validNickname(String value) {
  final length = value.runes.length;
  return length >= 1 &&
      length <= 64 &&
      utf8.encode(value).length <= 256 &&
      !value.runes.any((rune) => rune <= 0x1f || rune == 0x7f);
}

String _safeNickname(String? value) {
  final normalized = value?.trim() ?? '';
  return _validNickname(normalized) ? normalized : '我的';
}

String _safeMaskedPhone(String? value) {
  final normalized = value?.trim() ?? '';
  if (RegExp(r'^\d{11}$').hasMatch(normalized)) {
    return '${normalized.substring(0, 3)}****${normalized.substring(7)}';
  }
  if (normalized.length >= 7 && normalized.length <= 24) return normalized;
  return '未绑定';
}

String _profileSessionScope(SessionState session) {
  final userId = session.user?.userId.trim() ?? '';
  final workspaceId = session.workspace?.workspaceId?.trim();
  final workspaceScope = workspaceId == null || workspaceId.isEmpty
      ? 'profile-global'
      : workspaceId;
  return '${session.authState.name}|$userId|$workspaceScope';
}
