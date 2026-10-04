import 'package:huahuo_api/huahuo_api.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../application/profile_capability_controller.dart';
import '../domain/profile_capability_models.dart';

export '../application/profile_capability_controller.dart';

final class ProfileAccountSecurityDemoPort
    implements ProfileAccountSecurityPort {
  ProfileAccountSecuritySnapshot _snapshot =
      const ProfileAccountSecuritySnapshot(wechatBound: false, isDemo: true);

  @override
  ProfileAccountSecuritySnapshot get snapshot => _snapshot;

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  setWechatBound(bool bound) async {
    _snapshot = _snapshot.copyWith(wechatBound: bound);
    return ProfileCapabilityResult.success(_snapshot, isDemo: true);
  }

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> rebindPhone(
    String phone,
  ) async {
    final normalized = phone.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(normalized)) {
      return const ProfileCapabilityResult.failure(
        'PROFILE_PHONE_INVALID',
        isDemo: true,
      );
    }
    _snapshot = _snapshot.copyWith(
      maskedPhone:
          '${normalized.substring(0, 3)}****${normalized.substring(7)}',
    );
    return ProfileCapabilityResult.success(_snapshot, isDemo: true);
  }

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>> bindEmail(
    String email,
  ) async {
    final normalized = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(normalized)) {
      return const ProfileCapabilityResult.failure(
        'PROFILE_EMAIL_INVALID',
        isDemo: true,
      );
    }
    final separator = normalized.indexOf('@');
    final local = normalized.substring(0, separator);
    final maskedLocal = local.length <= 1 ? '*' : '${local[0]}***';
    _snapshot = _snapshot.copyWith(
      maskedEmail: '$maskedLocal${normalized.substring(separator)}',
    );
    return ProfileCapabilityResult.success(_snapshot, isDemo: true);
  }

  @override
  Future<ProfileCapabilityResult<ProfileAccountSecuritySnapshot>>
  changePassword(String password) {
    final valid = password.length >= 8;
    if (!valid) {
      return Future.value(
        const ProfileCapabilityResult.failure(
          'PROFILE_PASSWORD_INVALID',
          isDemo: true,
        ),
      );
    }
    // Only the validation outcome is retained; the password is never assigned.
    _snapshot = _snapshot.copyWith(passwordUpdatedAt: DateTime.now().toUtc());
    return Future.value(
      ProfileCapabilityResult.success(_snapshot, isDemo: true),
    );
  }
}

final class ProfileSupportDemoPort implements ProfileSupportPort {
  const ProfileSupportDemoPort();

  @override
  ProfileSupportContent get content => const ProfileSupportContent(
    manual: '依次完成内容采集、确认沉淀、思想图谱与自由创作。录音卡和声纹能力集中在录音卡入口。',
    featureIntroduction: '思想图谱连接已沉淀资产；创作空间提供热点、碰撞和大师升级；自由创作支持富文本、AI 技能与选区改写。',
    customerWechat: 'huahuo-service',
    qrSeed: 20260724,
    isDemo: true,
  );

  @override
  Future<ProfileCapabilityResult<bool>> submitBug(
    ProfileBugReportRequest request,
  ) async {
    if (request.description.trim().length < 5 ||
        request.description.length > 500) {
      return const ProfileCapabilityResult.failure(
        'PROFILE_BUG_DESCRIPTION_INVALID',
        isDemo: true,
      );
    }
    if (request.screenshotCount < 0 || request.screenshotCount > 3) {
      return const ProfileCapabilityResult.failure(
        'PROFILE_BUG_SCREENSHOT_LIMIT',
        isDemo: true,
      );
    }
    return const ProfileCapabilityResult.success(true, isDemo: true);
  }
}

typedef InstalledProfileVersionLoader = Future<ProfileVersionInfo> Function();

final class ProfileVersionDemoPort implements ProfileVersionPort {
  ProfileVersionDemoPort({
    this.delay = const Duration(milliseconds: 450),
    this.installedVersionTimeout = const Duration(milliseconds: 500),
    InstalledProfileVersionLoader? installedVersionLoader,
  }) : _installedVersionLoader =
           installedVersionLoader ?? _loadInstalledProfileVersion;

  final Duration delay;
  final Duration installedVersionTimeout;
  final InstalledProfileVersionLoader _installedVersionLoader;
  ProfileVersionInfo _current = fallbackCurrent;

  static const fallbackCurrent = ProfileVersionInfo(
    version: '0.1.0',
    buildNumber: '1',
    isDemo: true,
    releaseTitle: '无限花火 · 创作与资产闭环',
    releaseSummary: '本版本围绕 思想图谱、我的资产、自由创作和录音卡流程完成结构统一，并补齐离线帮助与主题设置。',
    highlights: <String>[
      '思想图谱仅使用已沉淀资产构建可交互关系图谱',
      '创作空间支持热点、碰撞、大师升级和自由创作历史',
      '录音转写、录音卡管理与声纹档案形成完整入口',
      '帮助中心和录音卡指南支持无网络离线查看',
    ],
  );

  @override
  ProfileVersionInfo get current => _current;

  @override
  Future<ProfileVersionInfo> loadCurrent() async {
    try {
      _current = await _installedVersionLoader().timeout(
        installedVersionTimeout,
      );
    } catch (_) {
      _current = fallbackCurrent;
    }
    return _current;
  }

  @override
  Future<ProfileCapabilityResult<ProfileVersionCheck>> checkForUpdate() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return const ProfileCapabilityResult.failure(
      'PROFILE_VERSION_CHECK_DEMO_UNAVAILABLE',
      isDemo: true,
    );
  }
}

final class ProfileVersionApiPort implements ProfileVersionPort {
  ProfileVersionApiPort({
    required ApiClient apiClient,
    InstalledProfileVersionLoader? installedVersionLoader,
    this.installedVersionTimeout = const Duration(milliseconds: 500),
  }) : // The public constructor name intentionally differs from the field.
       // ignore: prefer_initializing_formals
       _apiClient = apiClient,
       _installedVersionLoader =
           installedVersionLoader ?? _loadInstalledProfileVersion;

  final ApiClient _apiClient;
  final InstalledProfileVersionLoader _installedVersionLoader;
  final Duration installedVersionTimeout;
  ProfileVersionInfo _current = ProfileVersionDemoPort.fallbackCurrent;

  @override
  ProfileVersionInfo get current => _current;

  @override
  Future<ProfileVersionInfo> loadCurrent() async {
    try {
      _current = await _installedVersionLoader().timeout(
        installedVersionTimeout,
      );
    } catch (_) {
      _current = ProfileVersionDemoPort.fallbackCurrent;
    }
    return _current;
  }

  @override
  Future<ProfileCapabilityResult<ProfileVersionCheck>> checkForUpdate() async {
    final installed = await loadCurrent();
    final result = await _apiClient.request<ProfileVersionRemoteConfig>(
      const ApiRequestOptions<ProfileVersionRemoteConfig>(
        endpointId: 'appConfig',
        parseData: parseProfileVersionRemoteConfig,
      ),
    );
    final config = result.data;
    if (!result.ok || config == null) {
      return ProfileCapabilityResult.failure(
        result.error?.code ?? 'PROFILE_VERSION_CHECK_FAILED',
      );
    }
    return ProfileCapabilityResult.success(
      ProfileVersionCheck(
        current: installed,
        updateAvailable:
            compareProfileVersions(
              config.latestClientVersion,
              installed.version,
            ) >
            0,
        latestVersion: config.latestClientVersion,
      ),
    );
  }
}

final class ProfileVersionRemoteConfig {
  const ProfileVersionRemoteConfig({
    required this.latestClientVersion,
    required this.forceUpgrade,
  });

  final String latestClientVersion;
  final bool forceUpgrade;
}

ProfileVersionRemoteConfig parseProfileVersionRemoteConfig(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('PROFILE_VERSION_CONFIG_INVALID');
  }
  final latest = value['latestClientVersion'];
  final forceUpgrade = value['forceUpgrade'];
  if (latest is! String ||
      !_strictClientVersion.hasMatch(latest.trim()) ||
      forceUpgrade is! bool) {
    throw const FormatException('PROFILE_VERSION_CONFIG_INVALID');
  }
  return ProfileVersionRemoteConfig(
    latestClientVersion: latest.trim(),
    forceUpgrade: forceUpgrade,
  );
}

int compareProfileVersions(String left, String right) {
  if (!_strictClientVersion.hasMatch(left) ||
      !_strictClientVersion.hasMatch(right)) {
    throw const FormatException('PROFILE_VERSION_FORMAT_INVALID');
  }
  final leftCore = left.split(RegExp(r'[+-]')).first.split('.');
  final rightCore = right.split(RegExp(r'[+-]')).first.split('.');
  final length = leftCore.length > rightCore.length
      ? leftCore.length
      : rightCore.length;
  for (var index = 0; index < length; index++) {
    final leftPart = index < leftCore.length ? int.parse(leftCore[index]) : 0;
    final rightPart = index < rightCore.length
        ? int.parse(rightCore[index])
        : 0;
    if (leftPart != rightPart) return leftPart.compareTo(rightPart);
  }
  return 0;
}

Future<ProfileVersionInfo> _loadInstalledProfileVersion() async {
  final package = await PackageInfo.fromPlatform();
  const fallback = ProfileVersionDemoPort.fallbackCurrent;
  return ProfileVersionInfo(
    version: _safeVersionPart(package.version, fallback.version),
    buildNumber: _safeVersionPart(package.buildNumber, fallback.buildNumber),
    isDemo: false,
    releaseTitle: fallback.releaseTitle,
    releaseSummary: fallback.releaseSummary,
    highlights: fallback.highlights,
  );
}

String _safeVersionPart(String value, String fallback) {
  final normalized = value.trim();
  return normalized.isNotEmpty &&
          normalized.length <= 40 &&
          RegExp(r'^[0-9A-Za-z.+_-]+$').hasMatch(normalized)
      ? normalized
      : fallback;
}

final _strictClientVersion = RegExp(
  r'^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z._-]+)?$',
);
