import 'dart:async';

import '../../../core/database/user_metadata_dao.dart';
import 'voiceprint_api.dart';
import '../domain/voiceprint_profile.dart';

final class VoiceprintProfileSyncService {
  VoiceprintProfileSyncService({
    required VoiceprintApiPort api,
    required VoiceprintProfileRepository repository,
    bool Function()? isScopeActive,
  }) : _api = api,
       _repository = repository,
       _isScopeActive = isScopeActive ?? _alwaysActive;

  final VoiceprintApiPort _api;
  final VoiceprintProfileRepository _repository;
  final bool Function() _isScopeActive;
  Future<bool>? _inFlight;
  Future<bool>? _postMutationRefresh;
  int? _postMutationRefreshEpoch;
  int _mutationEpoch = 0;
  int _nextMutationId = 0;
  final Set<int> _activeMutationIds = <int>{};

  int get mutationEpoch => _mutationEpoch;
  bool get hasActiveMutation => _activeMutationIds.isNotEmpty;

  VoiceprintProfileMutationLease beginMutation() {
    final mutationId = _nextMutationId++;
    _activeMutationIds.add(mutationId);
    _mutationEpoch += 1;
    return VoiceprintProfileMutationLease._(this, mutationId);
  }

  Future<bool> sync() {
    final active = _inFlight;
    if (active != null) return active;
    late final Future<bool> operation;
    operation = _syncOnce();
    _inFlight = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_inFlight, operation)) _inFlight = null;
      }),
    );
    return operation;
  }

  Future<bool> _syncOnce() async {
    final requestEpoch = _mutationEpoch;
    if (!_isScopeActive() || _activeMutationIds.isNotEmpty) return false;
    try {
      final result = await _api.listProfiles();
      if (!_canApplySnapshot(requestEpoch) ||
          !result.ok ||
          result.value == null) {
        return false;
      }
      _repository.reconcileRemoteProfiles(
        projectRemoteVoiceprintProfiles(
          localProfiles: _repository.loadProfiles(),
          remoteProfiles: result.value!,
        ),
      );
      return _canApplySnapshot(requestEpoch);
    } catch (_) {
      return false;
    }
  }

  bool _canApplySnapshot(int requestEpoch) {
    return _isScopeActive() &&
        _activeMutationIds.isEmpty &&
        requestEpoch == _mutationEpoch;
  }

  Future<bool> _endMutation(int mutationId) {
    if (!_activeMutationIds.remove(mutationId)) {
      return Future<bool>.value(false);
    }
    _mutationEpoch += 1;
    if (_activeMutationIds.isNotEmpty) return Future<bool>.value(false);
    return _refreshAfterMutation(_mutationEpoch);
  }

  Future<bool> _refreshAfterMutation(int targetEpoch) {
    final active = _postMutationRefresh;
    if (active != null && _postMutationRefreshEpoch == targetEpoch) {
      return active;
    }
    late final Future<bool> operation;
    operation = _runPostMutationRefresh(targetEpoch);
    _postMutationRefresh = operation;
    _postMutationRefreshEpoch = targetEpoch;
    unawaited(
      operation.whenComplete(() {
        if (identical(_postMutationRefresh, operation)) {
          _postMutationRefresh = null;
          _postMutationRefreshEpoch = null;
        }
      }),
    );
    return operation;
  }

  Future<bool> _runPostMutationRefresh(int targetEpoch) async {
    final previous = _inFlight;
    if (previous != null) await previous;
    if (!_isScopeActive() ||
        _activeMutationIds.isNotEmpty ||
        targetEpoch != _mutationEpoch) {
      return false;
    }
    if (identical(_inFlight, previous)) _inFlight = null;
    return sync();
  }
}

final class VoiceprintProfileMutationLease {
  VoiceprintProfileMutationLease._(this._service, this._mutationId);

  final VoiceprintProfileSyncService _service;
  final int _mutationId;
  Future<bool>? _releaseFuture;

  Future<bool> releaseAndRefresh() {
    return _releaseFuture ??= _service._endMutation(_mutationId);
  }
}

final class VoiceprintProfileRepository {
  VoiceprintProfileRepository({
    required UserMetadataDao dao,
    required String userScope,
  }) : _dao = dao,
       _userScope = _normalize(userScope, 'userScope');

  final UserMetadataDao _dao;
  final String _userScope;

  String get userScope => _userScope;

  List<VoiceprintProfile> loadProfiles() {
    final profiles = <VoiceprintProfile>[
      for (final record in _dao.listVoiceprintProfiles(_userScope))
        if (_profileFromRecord(record) case final profile?) profile,
    ]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<VoiceprintProfile>.unmodifiable(profiles);
  }

  void saveProfile(VoiceprintProfile profile) {
    final id = _normalize(profile.id, 'profile.id');
    final name = normalizeVoiceprintProfileName(profile.name);
    if (name == null) {
      throw ArgumentError.value(profile.name, 'profile.name', 'invalid name');
    }
    _dao.upsertVoiceprintProfile(
      userScope: _userScope,
      profileId: id,
      name: name,
      enrolledAt: profile.enrolledAt.toUtc().toIso8601String(),
      updatedAt: profile.updatedAt.toUtc().toIso8601String(),
      isDemo: profile.isDemo,
    );
  }

  void replaceProfile({
    required String existingProfileId,
    required VoiceprintProfile replacement,
  }) {
    final existingId = _normalize(existingProfileId, 'existingProfileId');
    final replacementId = _normalize(replacement.id, 'replacement.id');
    final name = normalizeVoiceprintProfileName(replacement.name);
    if (name == null) {
      throw ArgumentError.value(
        replacement.name,
        'replacement.name',
        'invalid name',
      );
    }
    saveProfile(replacement);
    if (existingId != replacementId) {
      _dao.deleteVoiceprintProfile(
        userScope: _userScope,
        profileId: existingId,
      );
    }
  }

  List<VoiceprintProfile> reconcileRemoteProfiles(
    List<VoiceprintProfile> remoteProfiles,
  ) {
    final localById = <String, VoiceprintProfile>{
      for (final profile in loadProfiles()) profile.id: profile,
    };
    final remoteIds = <String>{};
    final validated = <VoiceprintProfile>[];
    for (final profile in remoteProfiles) {
      final id = _normalize(profile.id, 'profile.id');
      if (!remoteIds.add(id)) {
        throw ArgumentError.value(id, 'profile.id', 'duplicate profile id');
      }
      if (profile.isDemo) {
        throw ArgumentError.value(
          profile.isDemo,
          'profile.isDemo',
          'remote profile must not be demo',
        );
      }
      final name = normalizeVoiceprintProfileName(
        localById[id]?.name ?? profile.name,
      );
      if (name == null) {
        throw ArgumentError.value(profile.name, 'profile.name', 'invalid name');
      }
      validated.add(
        VoiceprintProfile(
          id: id,
          name: name,
          enrolledAt: profile.enrolledAt,
          updatedAt: profile.updatedAt,
          isDemo: false,
        ),
      );
    }

    for (final profile in validated) {
      saveProfile(profile);
    }
    for (final profile in localById.values) {
      if (!profile.isDemo && !remoteIds.contains(profile.id)) {
        _dao.deleteVoiceprintProfile(
          userScope: _userScope,
          profileId: profile.id,
        );
      }
    }
    return loadProfiles();
  }

  void deleteProfile(String profileId) {
    _dao.deleteVoiceprintProfile(
      userScope: _userScope,
      profileId: _normalize(profileId, 'profileId'),
    );
  }
}

List<VoiceprintProfile> projectRemoteVoiceprintProfiles({
  required List<VoiceprintProfile> localProfiles,
  required List<VoiceprintRemoteProfile> remoteProfiles,
}) {
  final activeRemoteIds = <String>{
    for (final profile in remoteProfiles)
      if (profile.isActive) profile.profileId,
  };
  final localById = <String, VoiceprintProfile>{
    for (final profile in localProfiles) profile.id: profile,
  };
  final usedNames = <String>{
    for (final profile in localProfiles)
      if (profile.isDemo || activeRemoteIds.contains(profile.id))
        profile.name.toLowerCase(),
  };

  String nextGenericName() {
    const baseName = '我的声纹';
    if (usedNames.add(baseName.toLowerCase())) return baseName;
    var suffix = 2;
    while (true) {
      final candidate = '$baseName $suffix';
      if (usedNames.add(candidate.toLowerCase())) return candidate;
      suffix += 1;
    }
  }

  return <VoiceprintProfile>[
    for (final remote in remoteProfiles)
      if (remote.isActive)
        VoiceprintProfile(
          id: remote.profileId,
          name: localById[remote.profileId]?.name ?? nextGenericName(),
          enrolledAt: remote.registeredAt,
          updatedAt: remote.updatedAt,
          isDemo: false,
        ),
  ];
}

String? normalizeVoiceprintProfileName(String raw) {
  final value = raw.trim();
  final length = value.runes.length;
  return value.isEmpty || length > 24 ? null : value;
}

VoiceprintProfile? _profileFromRecord(Map<String, Object?> record) {
  final id = _nonEmpty(record['profile_id']);
  final name = normalizeVoiceprintProfileName('${record['name'] ?? ''}');
  final enrolledAt = DateTime.tryParse('${record['enrolled_at'] ?? ''}');
  final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
  final isDemo = record['is_demo'];
  if (id == null ||
      name == null ||
      enrolledAt == null ||
      updatedAt == null ||
      isDemo is! bool) {
    return null;
  }
  return VoiceprintProfile(
    id: id,
    name: name,
    enrolledAt: enrolledAt,
    updatedAt: updatedAt,
    isDemo: isDemo,
  );
}

String _normalize(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _nonEmpty(Object? raw) {
  final value = '${raw ?? ''}'.trim();
  return value.isEmpty ? null : value;
}

bool _alwaysActive() => true;
