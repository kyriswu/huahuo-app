import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/user_profile_controller.dart';
import 'package:image/image.dart' as image;

void main() {
  test(
    'avatar decode resize and JPEG encoding run through worker contract',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'profile-avatar-worker-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source.png');
      final orchestrator = TaskOrchestrator();
      addTearDown(orchestrator.dispose);
      final original = image.Image(width: 1600, height: 800);
      image.fill(original, color: image.ColorRgb8(18, 92, 140));
      await source.writeAsBytes(image.encodePng(original));
      final port = RemoteUserProfilePort(
        apiClient: _profileApiClient(
          _ProfileQueueTransport(<ApiTransportResponse>[]),
        ),
        nativeFilePort: _PickedAvatarNativeFilePort(source),
        temporaryDirectory: () async => root,
        now: () => DateTime.utc(2026, 8, 31, 8),
        taskOrchestrator: orchestrator,
      );
      port.beginSession(_authenticatedSession());

      final result = await port.chooseAvatar(
        UserProfileAvatarSource.photoLibrary,
      );

      expect(result.ok, isTrue);
      final avatar = result.value!;
      expect(avatar.sizeBytes, lessThanOrEqualTo(2 * 1024 * 1024));
      final output = File(avatar.localPath!);
      final bytes = await output.readAsBytes();
      expect(sha256.convert(bytes).toString(), avatar.sha256);
      final decoded = image.decodeJpg(bytes)!;
      expect(decoded.width, 1024);
      expect(decoded.height, 512);
      final task = orchestrator.snapshot.projections.singleWhere(
        (projection) => projection.spec.owner == 'profile-avatar-transform',
      );
      expect(task.spec.resources, <TaskResource>{
        TaskResource.cpu,
        TaskResource.media,
      });
      expect(task.spec.key, startsWith('profile:avatar-transform:'));
      expect(task.spec.key, isNot(contains(source.path)));
    },
  );

  test(
    'profile mock saves only valid session-scoped avatar and nickname',
    () async {
      final port = SessionMockUserProfilePort(
        now: () => DateTime.utc(2026, 7, 15, 8),
      );
      final controller = UserProfileController(
        port: port,
        initialSession: _authenticatedSession(),
      );

      expect(controller.state.profile.nickname, '原昵称');
      expect(controller.state.profile.maskedPhoneNumber, '138****8000');

      expect(
        await controller.chooseAvatar(UserProfileAvatarSource.photoLibrary),
        isTrue,
      );
      controller.updateNickname('  新昵称  ');
      expect(await controller.save(), isTrue);
      expect(controller.state.profile.nickname, '新昵称');
      expect(
        controller.state.profile.avatar?.source,
        UserProfileAvatarSource.photoLibrary,
      );
      expect(controller.state.profile.isDemo, isTrue);

      controller.syncSession(SessionState.anonymous());
      expect(controller.state.profile.userId, isNull);
      expect(controller.state.profile.nickname, '我的');
      expect(controller.state.profile.avatar, isNull);

      controller.dispose();
    },
  );

  test(
    'restores a fresh safe profile cache and replaces it after save',
    () async {
      final session = _authenticatedSession();
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'profile-cache-user',
        workspaceScope: 'profile-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      final remote = _CountingRemoteUserProfilePort(loadedNickname: '云端昵称');
      final controller = UserProfileController(
        port: remote,
        initialSession: session,
        cacheForSession: (_) => cache,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(remote.loadCalls, 1);
      expect(controller.state.profile.nickname, '云端昵称');
      controller.updateNickname('已保存昵称');
      expect(await controller.save(), isTrue);

      final restoredPort = _CountingRemoteUserProfilePort(
        loadedNickname: '不应请求',
      );
      final restored = UserProfileController(
        port: restoredPort,
        initialSession: session,
        cacheForSession: (_) => cache,
      );
      await Future<void>.delayed(Duration.zero);

      expect(restored.state.profile.nickname, '已保存昵称');
      expect(restoredPort.loadCalls, 0);
      controller.dispose();
      restored.dispose();
    },
  );

  test('switches to the unchanged account workspace cache', () async {
    final dao = AppPreferencesDao(AppDatabase());
    final workspaceA = ScopedReadCache(
      dao: dao,
      userScope: 'profile-cache-user',
      workspaceScope: 'workspace-a',
      now: () => DateTime.utc(2026, 8, 19, 8),
    );
    final workspaceB = ScopedReadCache(
      dao: dao,
      userScope: 'profile-cache-user',
      workspaceScope: 'workspace-b',
      now: () => DateTime.utc(2026, 8, 19, 8),
    );
    workspaceA.write(
      'meProfile',
      'profile',
      etag: null,
      payload: const <String, Object?>{'nickname': '工作区 A'},
    );
    workspaceB.write(
      'meProfile',
      'profile',
      etag: null,
      payload: const <String, Object?>{'nickname': '工作区 B'},
    );
    final remote = _CountingRemoteUserProfilePort(loadedNickname: '不应请求');
    final controller = UserProfileController(
      port: remote,
      initialSession: _authenticatedSession(workspaceId: 'workspace-a'),
      cacheForSession: (session) =>
          session.workspace?.workspaceId == 'workspace-b'
          ? workspaceB
          : workspaceA,
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.profile.nickname, '工作区 A');
    expect(remote.loadCalls, 0);

    controller.syncSession(_authenticatedSession(workspaceId: 'workspace-b'));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.profile.nickname, '工作区 B');
    expect(remote.loadCalls, 0);
    controller.dispose();
  });

  test(
    'nickname validation preserves invalid draft and camera selection works',
    () async {
      final controller = UserProfileController(
        port: SessionMockUserProfilePort(),
        initialSession: _authenticatedSession(),
      );

      controller.updateNickname('');
      expect(await controller.save(), isFalse);
      expect(controller.state.errorCode, 'USER_PROFILE_NICKNAME_INVALID');
      expect(controller.state.draftNickname, '');

      final tooLongNickname = List<String>.filled(65, '声').join();
      controller.updateNickname(tooLongNickname);
      expect(await controller.save(), isFalse);
      expect(controller.state.draftNickname, tooLongNickname);

      controller.updateNickname('可用昵称');
      expect(
        await controller.chooseAvatar(UserProfileAvatarSource.camera),
        isTrue,
      );
      expect(
        controller.state.draftAvatar?.source,
        UserProfileAvatarSource.camera,
      );
      expect(await controller.save(), isTrue);

      controller.dispose();
    },
  );

  test('delayed avatar result cannot cross an account switch', () async {
    final port = _DelayedUserProfilePort();
    final controller = UserProfileController(
      port: port,
      initialSession: _authenticatedSession(),
    );

    final choosing = controller.chooseAvatar(
      UserProfileAvatarSource.photoLibrary,
    );
    expect(controller.state.status, UserProfileSaveStatus.idle);
    expect(
      await controller.chooseAvatar(UserProfileAvatarSource.camera),
      isFalse,
    );
    expect(port.avatarPickerCalls, 1);

    controller.syncSession(
      _authenticatedSession(
        userId: 'user-profile-2',
        displayName: '第二个账号',
        maskedPhoneNumber: '139****9000',
      ),
    );
    port.avatarCompleter.complete(
      UserProfileResult.success(
        const UserProfileAvatar(
          source: UserProfileAvatarSource.photoLibrary,
          revision: 1,
        ),
      ),
    );

    expect(await choosing, isFalse);
    expect(controller.state.profile.userId, 'user-profile-2');
    expect(controller.state.profile.nickname, '第二个账号');
    expect(controller.state.draftAvatar, isNull);
    expect(controller.state.status, UserProfileSaveStatus.idle);

    controller.dispose();
  });

  test('delayed save result cannot restore data after logout', () async {
    final port = _DelayedUserProfilePort();
    final controller = UserProfileController(
      port: port,
      initialSession: _authenticatedSession(),
    );
    controller.updateNickname('旧账号的新昵称');

    final saving = controller.save();
    expect(controller.state.status, UserProfileSaveStatus.saving);
    controller.syncSession(SessionState.anonymous());
    port.saveCompleter.complete(
      UserProfileResult.success(
        const UserProfileSnapshot(
          userId: 'user-profile-1',
          nickname: '旧账号的新昵称',
          maskedPhoneNumber: '138****8000',
          authenticated: true,
          isDemo: true,
        ),
      ),
    );

    expect(await saving, isFalse);
    expect(controller.state.profile.userId, isNull);
    expect(controller.state.profile.nickname, '我的');
    expect(controller.state.draftNickname, '我的');
    expect(controller.state.status, UserProfileSaveStatus.idle);

    controller.dispose();
  });

  test(
    'remote profile follows avatar upload, PATCH, and reload contract',
    () async {
      final directory = await Directory.systemTemp.createTemp('profile-port-');
      addTearDown(() => directory.delete(recursive: true));
      final avatarFile = File('${directory.path}/avatar.jpg');
      await avatarFile.writeAsBytes(<int>[1, 2, 3, 4]);
      final transport = _ProfileQueueTransport(<ApiTransportResponse>[
        _profileResponse(displayName: '原昵称'),
        _successResponse(<String, Object?>{
          'uploadId': 'upload-avatar-1',
          'uploadUrl': 'https://objects.example.test/avatar-1',
          'method': 'PUT',
          'headers': <String, Object?>{},
        }),
        _successResponse(<String, Object?>{
          'uploadId': 'upload-avatar-1',
          'resource': <String, Object?>{
            'resourceId': 'resource-avatar-1',
            'sourceScene': 'avatar',
            'mimeType': 'image/jpeg',
            'sizeBytes': 4,
            'durationSeconds': 0,
          },
        }),
        _profileResponse(
          displayName: '云端昵称',
          avatarResourceId: 'resource-avatar-1',
        ),
        _successResponse(<String, Object?>{
          'url': 'https://cdn.example.test/avatar-1.jpg',
          'resource': <String, Object?>{
            'resourceId': 'resource-avatar-1',
            'status': 'available',
          },
        }),
        _profileResponse(
          displayName: '云端昵称',
          avatarResourceId: 'resource-avatar-1',
        ),
        _successResponse(<String, Object?>{
          'url': 'https://cdn.example.test/avatar-1.jpg',
          'resource': <String, Object?>{
            'resourceId': 'resource-avatar-1',
            'status': 'available',
          },
        }),
      ]);
      final uploaded = _AvatarObjectTransport();
      final port = RemoteUserProfilePort(
        apiClient: _profileApiClient(transport),
        nativeFilePort: const _UnusedNativeFilePort(),
        objectUploadTransport: uploaded,
        now: () => DateTime.utc(2026, 8, 11, 8),
      );
      final session = _authenticatedSession();
      final initial = await port.load(session);

      expect(initial.ok, isTrue);
      expect(initial.value?.nickname, '原昵称');
      final invalid = await port.save(
        base: initial.value!,
        nickname: '',
        avatar: null,
      );
      expect(invalid.ok, isFalse);
      expect(invalid.errorCode, 'USER_PROFILE_NICKNAME_INVALID');
      expect(transport.requests, hasLength(1));

      final avatar = UserProfileAvatar(
        source: UserProfileAvatarSource.photoLibrary,
        revision: 1,
        localPath: avatarFile.path,
        mimeType: 'image/jpeg',
        sizeBytes: 4,
        sha256: List<String>.filled(64, 'a').join(),
      );
      final saved = await port.save(
        base: initial.value!,
        nickname: '云端昵称',
        avatar: avatar,
      );
      final reloaded = await port.load(session);

      expect(saved.ok, isTrue);
      expect(saved.value?.avatar?.avatarResourceId, 'resource-avatar-1');
      expect(saved.value?.avatar?.playbackUrl?.host, 'cdn.example.test');
      expect(reloaded.value?.nickname, '云端昵称');
      expect(reloaded.value?.avatar?.avatarResourceId, 'resource-avatar-1');
      expect(uploaded.requests.single.sizeBytes, 4);
      expect(
        transport.requests.map(
          (request) => '${request.method} ${request.url.path}',
        ),
        <String>[
          'GET /api/v1/me/profile',
          'POST /api/v1/media/upload-token',
          'POST /api/v1/media/uploads/upload-avatar-1/complete',
          'PATCH /api/v1/me/profile',
          'GET /api/v1/media/resources/resource-avatar-1/playback',
          'GET /api/v1/me/profile',
          'GET /api/v1/media/resources/resource-avatar-1/playback',
        ],
      );
      expect(_requestBody(transport.requests[1])['sourceScene'], 'avatar');
      expect(_requestBody(transport.requests[3]), <String, Object?>{
        'displayName': '云端昵称',
        'avatarResourceId': 'resource-avatar-1',
      });
    },
  );

  test(
    'remote profile accepts an empty first-run nickname in a formal envelope',
    () async {
      final transport = _ProfileQueueTransport(<ApiTransportResponse>[
        _profileResponse(displayName: ''),
      ]);
      final port = RemoteUserProfilePort(
        apiClient: _profileApiClient(transport),
        nativeFilePort: const _UnusedNativeFilePort(),
      );

      final loaded = await port.load(_authenticatedSession(displayName: '我的'));

      expect(loaded.ok, isTrue);
      expect(loaded.value?.nickname, '我的');
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.url.path, '/api/v1/me/profile');
    },
  );
}

SessionState _authenticatedSession({
  String userId = 'user-profile-1',
  String displayName = '原昵称',
  String maskedPhoneNumber = '138****8000',
  String? workspaceId,
}) {
  final session = SessionState.anonymous().copyWith(
    authState: SessionAuthState.authenticated,
    user: SessionUser(
      userId: userId,
      maskedPhoneNumber: maskedPhoneNumber,
      displayName: displayName,
    ),
  );
  if (workspaceId == null) return session;
  return session.copyWith(
    workspaceStatus: SessionWorkspaceStatus.ready,
    workspace: SessionWorkspace(
      status: SessionWorkspaceStatus.ready,
      workspaceId: workspaceId,
    ),
  );
}

final class _DelayedUserProfilePort implements UserProfilePort {
  final avatarCompleter = Completer<UserProfileResult<UserProfileAvatar>>();
  final saveCompleter = Completer<UserProfileResult<UserProfileSnapshot>>();
  var avatarPickerCalls = 0;

  @override
  UserProfileSnapshot beginSession(SessionState session) {
    final user = session.user;
    final authenticated =
        session.authState == SessionAuthState.authenticated && user != null;
    return UserProfileSnapshot(
      userId: authenticated ? user.userId : null,
      nickname: authenticated ? user.displayName ?? '我的' : '我的',
      maskedPhoneNumber: authenticated ? user.maskedPhoneNumber : '未绑定',
      authenticated: authenticated,
    );
  }

  @override
  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  ) {
    avatarPickerCalls += 1;
    return avatarCompleter.future;
  }

  @override
  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  }) {
    return saveCompleter.future;
  }
}

final class _CountingRemoteUserProfilePort
    implements UserProfilePort, UserProfileRemoteLoadPort {
  _CountingRemoteUserProfilePort({required this.loadedNickname});

  final String loadedNickname;
  int loadCalls = 0;

  @override
  UserProfileSnapshot beginSession(SessionState session) {
    final user = session.user;
    final authenticated =
        session.authState == SessionAuthState.authenticated && user != null;
    return UserProfileSnapshot(
      userId: authenticated ? user.userId : null,
      nickname: authenticated ? user.displayName ?? '我的' : '我的',
      maskedPhoneNumber: authenticated ? user.maskedPhoneNumber : '未绑定',
      authenticated: authenticated,
    );
  }

  @override
  Future<UserProfileResult<UserProfileSnapshot>> load(
    SessionState session,
  ) async {
    loadCalls += 1;
    final base = beginSession(session);
    return UserProfileResult.success(
      UserProfileSnapshot(
        userId: base.userId,
        nickname: loadedNickname,
        maskedPhoneNumber: base.maskedPhoneNumber,
        authenticated: base.authenticated,
        avatar: const UserProfileAvatar(
          source: UserProfileAvatarSource.photoLibrary,
          revision: 1,
          avatarResourceId: 'cached-avatar-resource',
        ),
      ),
    );
  }

  @override
  Future<UserProfileResult<UserProfileAvatar>> chooseAvatar(
    UserProfileAvatarSource source,
  ) async => UserProfileResult.failure('UNUSED');

  @override
  Future<UserProfileResult<UserProfileSnapshot>> save({
    required UserProfileSnapshot base,
    required String nickname,
    required UserProfileAvatar? avatar,
  }) async => UserProfileResult.success(
    UserProfileSnapshot(
      userId: base.userId,
      nickname: nickname,
      maskedPhoneNumber: base.maskedPhoneNumber,
      authenticated: base.authenticated,
      avatar: avatar,
    ),
  );
}

ApiClient _profileApiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-profile',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _successResponse(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

ApiTransportResponse _profileResponse({
  required String displayName,
  String? avatarResourceId,
}) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'userId': 'user-profile-1',
      'displayName': displayName,
      'avatarResourceId': avatarResourceId,
      'updatedAt': '2026-08-11T08:00:00Z',
    },
  },
);

Map<String, Object?> _requestBody(ApiTransportRequest request) =>
    (jsonDecode(request.body ?? '{}') as Map<String, dynamic>)
        .cast<String, Object?>();

final class _ProfileQueueTransport implements ApiTransport {
  _ProfileQueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('unexpected profile request');
    return _responses.removeAt(0);
  }
}

final class _AvatarObjectTransport implements ObjectUploadTransport {
  final List<ObjectUploadRequest> requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    requests.add(request);
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}

final class _UnusedNativeFilePort implements NativeFilePort {
  const _UnusedNativeFilePort();

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    throw StateError('unexpected media selection');
  }
}

final class _PickedAvatarNativeFilePort
    implements NativeFilePort, NativeMediaFilePort {
  const _PickedAvatarNativeFilePort(this.file);

  final File file;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    throw StateError('unexpected audio selection');
  }

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async => NativeFileResult<List<PickedMediaFile>>.success(<PickedMediaFile>[
    PickedMediaFile(
      pickerRef: 'avatar-source',
      displayName: 'source.png',
      mimeType: 'image/png',
      sizeBytes: await file.length(),
      kind: NativeMediaKind.image,
      source: source,
      sourcePath: file.path,
    ),
  ]);
}
