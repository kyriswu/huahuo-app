import 'package:flutter/foundation.dart';

@immutable
final class ProfileCapabilityResult<T> {
  const ProfileCapabilityResult.success(this.data, {this.isDemo = false})
    : errorCode = null;

  const ProfileCapabilityResult.failure(this.errorCode, {this.isDemo = false})
    : data = null;

  final T? data;
  final String? errorCode;
  final bool isDemo;

  bool get ok => errorCode == null && data != null;
}

@immutable
final class ProfileAccountSecuritySnapshot {
  const ProfileAccountSecuritySnapshot({
    required this.wechatBound,
    required this.isDemo,
    this.maskedPhone,
    this.maskedEmail,
    this.passwordUpdatedAt,
  });

  final bool wechatBound;
  final String? maskedPhone;
  final String? maskedEmail;
  final DateTime? passwordUpdatedAt;
  final bool isDemo;

  ProfileAccountSecuritySnapshot copyWith({
    bool? wechatBound,
    String? maskedPhone,
    String? maskedEmail,
    DateTime? passwordUpdatedAt,
  }) {
    return ProfileAccountSecuritySnapshot(
      wechatBound: wechatBound ?? this.wechatBound,
      maskedPhone: maskedPhone ?? this.maskedPhone,
      maskedEmail: maskedEmail ?? this.maskedEmail,
      passwordUpdatedAt: passwordUpdatedAt ?? this.passwordUpdatedAt,
      isDemo: isDemo,
    );
  }
}

@immutable
final class ProfileSupportContent {
  const ProfileSupportContent({
    required this.manual,
    required this.featureIntroduction,
    required this.customerWechat,
    required this.qrSeed,
    required this.isDemo,
  });

  final String manual;
  final String featureIntroduction;
  final String customerWechat;
  final int qrSeed;
  final bool isDemo;
}

@immutable
final class ProfileBugReportRequest {
  const ProfileBugReportRequest({
    required this.description,
    required this.screenshotCount,
    required this.includeDiagnostics,
  }) : assert(screenshotCount >= 0 && screenshotCount <= 3);

  final String description;
  final int screenshotCount;
  final bool includeDiagnostics;

  bool get hasScreenshots => screenshotCount > 0;
}

@immutable
final class ProfileVersionInfo {
  const ProfileVersionInfo({
    required this.version,
    required this.buildNumber,
    required this.isDemo,
    this.releaseTitle = '当前版本',
    this.releaseSummary = '',
    this.highlights = const <String>[],
  });

  final String version;
  final String buildNumber;
  final bool isDemo;
  final String releaseTitle;
  final String releaseSummary;
  final List<String> highlights;

  String get displayLabel => '$version ($buildNumber)';
}

@immutable
final class ProfileVersionCheck {
  const ProfileVersionCheck({
    required this.current,
    required this.updateAvailable,
    this.latestVersion,
  });

  final ProfileVersionInfo current;
  final bool updateAvailable;
  final String? latestVersion;
}
