import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/profile_capability_models.dart';

// resident-provider: Shares one profile account security port dependency for the full account session.
final profileAccountSecurityPortProvider = Provider<ProfileAccountSecurityPort>(
  (ref) => const UnavailableProfileAccountSecurityPort(),
);

// resident-provider: Shares one profile support port dependency for the full account session.
final profileSupportPortProvider = Provider<ProfileSupportPort>(
  (ref) => const UnavailableProfileSupportPort(),
);

final profileAccountSecurityControllerProvider =
    Provider.autoDispose<ProfileAccountSecurityController>(
      (ref) => ProfileAccountSecurityController(
        ref.watch(profileAccountSecurityPortProvider),
      ),
    );

abstract interface class ProfileAccountSecurityPort {
  ProfileAccountSecuritySnapshot get snapshot;

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  setWechatBound(bool bound);

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> rebindPhone(
    String phone,
  );

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> bindEmail(
    String email,
  );

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  changePassword(String password);
}

final class ProfileAccountSecurityController {
  const ProfileAccountSecurityController(this._port);

  final ProfileAccountSecurityPort _port;

  ProfileAccountSecuritySnapshot get snapshot => _port.snapshot;

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  setWechatBound(bool bound) => _port.setWechatBound(bound);

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> rebindPhone(
    String phone,
  ) => _port.rebindPhone(phone);

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> bindEmail(
    String email,
  ) => _port.bindEmail(email);

  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  changePassword(String password) => _port.changePassword(password);
}

final class UnavailableProfileAccountSecurityPort
    implements ProfileAccountSecurityPort {
  const UnavailableProfileAccountSecurityPort();

  @override
  ProfileAccountSecuritySnapshot get snapshot =>
      const ProfileAccountSecuritySnapshot(wechatBound: false, isDemo: false);

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> bindEmail(
    String email,
  ) async => const ProfileCapabilityResult.failure(
    'PROFILE_ACCOUNT_SECURITY_BACKEND_UNAVAILABLE',
  );

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  changePassword(String password) async =>
      const ProfileCapabilityResult.failure(
        'PROFILE_ACCOUNT_SECURITY_BACKEND_UNAVAILABLE',
      );

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> rebindPhone(
    String phone,
  ) async => const ProfileCapabilityResult.failure(
    'PROFILE_ACCOUNT_SECURITY_BACKEND_UNAVAILABLE',
  );

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  setWechatBound(bool bound) async => const ProfileCapabilityResult.failure(
    'PROFILE_ACCOUNT_SECURITY_BACKEND_UNAVAILABLE',
  );
}

abstract interface class ProfileSupportPort {
  ProfileSupportContent get content;

  Future<ProfileCapabilityResult<bool>> submitBug(
    ProfileBugReportRequest request,
  );
}

final class UnavailableProfileSupportPort implements ProfileSupportPort {
  const UnavailableProfileSupportPort();

  @override
  ProfileSupportContent get content => const ProfileSupportContent(
    manual: '',
    featureIntroduction: '',
    customerWechat: '',
    qrSeed: 0,
    isDemo: false,
  );

  @override
  Future<ProfileCapabilityResult<bool>> submitBug(
    ProfileBugReportRequest request,
  ) async => const ProfileCapabilityResult.failure(
    'PROFILE_SUPPORT_BACKEND_UNAVAILABLE',
  );
}

abstract interface class ProfileVersionPort {
  ProfileVersionInfo get current;

  Future<ProfileVersionInfo> loadCurrent();

  Future<ProfileCapabilityResult<ProfileVersionCheck>> checkForUpdate();
}

final class ProfileVersionController {
  const ProfileVersionController(this._port);

  final ProfileVersionPort _port;

  ProfileVersionInfo get current => _port.current;

  Future<ProfileVersionInfo> loadCurrent() => _port.loadCurrent();

  Future<ProfileCapabilityResult<ProfileVersionCheck>> checkForUpdate() =>
      _port.checkForUpdate();
}
