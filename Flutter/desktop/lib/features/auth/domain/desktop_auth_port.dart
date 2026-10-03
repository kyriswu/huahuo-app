import '../../../shared/services/desktop_service_result.dart';

final class DesktopAuthRuntime {
  const DesktopAuthRuntime({
    required this.deviceId,
    required this.clientVersion,
    required this.timeZone,
    this.agreementVersion = 'v0.1',
    this.privacyVersion = 'v0.1',
  });

  final String deviceId;
  final String clientVersion;
  final String timeZone;
  final String agreementVersion;
  final String privacyVersion;
}

final class DesktopAuthAccount {
  const DesktopAuthAccount({
    required this.userId,
    required this.displayName,
    required this.workspaceStatus,
    required this.workspaceId,
  });

  final String userId;
  final String displayName;
  final String workspaceStatus;
  final String? workspaceId;
}

final class DesktopSmsChallenge {
  const DesktopSmsChallenge({
    required this.smsRequestId,
    required this.cooldownSeconds,
  });

  final String smsRequestId;
  final int cooldownSeconds;
}

final class DesktopUserProfile {
  const DesktopUserProfile({required this.displayName, this.avatarResourceId});

  final String displayName;
  final String? avatarResourceId;
}

abstract interface class DesktopAuthPort {
  Future<DesktopServiceResult<DesktopAuthAccount?>> restoreSession();

  Future<DesktopServiceResult<DesktopSmsChallenge>> requestSmsCode(
    String phone,
  );

  Future<DesktopServiceResult<DesktopAuthAccount>> signIn({
    required String phone,
    required String smsRequestId,
    required String code,
    required bool agreementAccepted,
  });

  Future<DesktopServiceResult<DesktopUserProfile>> loadProfile();

  Future<DesktopServiceResult<DesktopUserProfile>> updateProfile({
    required String displayName,
  });

  /// Requests another server-owned Workspace initialization only after the
  /// public status is `sync_failed`.
  Future<DesktopServiceResult<void>> retryWorkspaceCreation();

  Future<DesktopServiceResult<void>> signOut();
}
