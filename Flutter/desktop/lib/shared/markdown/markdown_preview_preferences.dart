import 'package:flutter/foundation.dart';

/// App-shipped presentation themes for Markdown reading.
///
/// These IDs are deliberately stable so an assistant can recommend a theme
/// without producing arbitrary HTML or CSS. The registry is local for now;
/// there is no download or marketplace surface.
enum MarkdownPreviewTheme {
  quiet(storageValue: 'quiet', label: '安静阅读', description: '克制留白，适合日常长文。'),
  paper(storageValue: 'paper', label: '纸页', description: '收束版心，接近纸面阅读。'),
  editorial(
    storageValue: 'editorial',
    label: '杂志',
    description: '强化标题层级，适合专题内容。',
  ),
  focus(storageValue: 'focus', label: '沉浸', description: '窄版心和舒展行距，适合连续阅读。'),
  research(
    storageValue: 'research',
    label: '研读',
    description: '目录和引文更突出，适合资料梳理。',
  ),
  brief(storageValue: 'brief', label: '简报', description: '更高信息密度，适合计划与报告。');

  const MarkdownPreviewTheme({
    required this.storageValue,
    required this.label,
    required this.description,
  });

  final String storageValue;
  final String label;
  final String description;

  static MarkdownPreviewTheme? tryParse(String? value) {
    for (final theme in MarkdownPreviewTheme.values) {
      if (theme.storageValue == value) return theme;
    }
    return null;
  }
}

/// The reading density applied to Markdown preview documents.
enum MarkdownPreviewProfile {
  quiet('quiet'),
  compact('compact'),
  paper('paper');

  const MarkdownPreviewProfile(this.storageValue);

  final String storageValue;

  static MarkdownPreviewProfile? tryParse(String? value) {
    for (final profile in MarkdownPreviewProfile.values) {
      if (profile.storageValue == value) return profile;
    }
    return null;
  }
}

/// Chooses whether Markdown preview follows the app appearance or is fixed.
enum MarkdownPreviewColorMode {
  system('system'),
  light('light'),
  dark('dark');

  const MarkdownPreviewColorMode(this.storageValue);

  final String storageValue;

  static MarkdownPreviewColorMode? tryParse(String? value) {
    for (final mode in MarkdownPreviewColorMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return null;
  }
}

/// Persistable preferences for the document Markdown preview.
///
/// The defaults deliberately render a static, offline-friendly document.
/// Enabling a preference only changes the preview surface; it never enables
/// raw HTML or scripts from the document source.
@immutable
final class MarkdownPreviewPreferences {
  const MarkdownPreviewPreferences({
    this.theme = MarkdownPreviewTheme.quiet,
    this.profile = MarkdownPreviewProfile.quiet,
    this.colorMode = MarkdownPreviewColorMode.system,
    this.textScale = 1,
    this.showTableOfContents = true,
    this.allowRemoteImages = false,
  }) : assert(textScale >= minimumTextScale && textScale <= maximumTextScale);

  static const double minimumTextScale = .8;
  static const double maximumTextScale = 1.6;

  static const MarkdownPreviewPreferences defaults =
      MarkdownPreviewPreferences();

  final MarkdownPreviewTheme theme;
  final MarkdownPreviewProfile profile;
  final MarkdownPreviewColorMode colorMode;
  final double textScale;
  final bool showTableOfContents;
  final bool allowRemoteImages;

  MarkdownPreviewPreferences copyWith({
    MarkdownPreviewTheme? theme,
    MarkdownPreviewProfile? profile,
    MarkdownPreviewColorMode? colorMode,
    double? textScale,
    bool? showTableOfContents,
    bool? allowRemoteImages,
  }) {
    final nextTextScale = textScale ?? this.textScale;
    return MarkdownPreviewPreferences(
      theme: theme ?? this.theme,
      profile: profile ?? this.profile,
      colorMode: colorMode ?? this.colorMode,
      textScale: nextTextScale.clamp(minimumTextScale, maximumTextScale),
      showTableOfContents: showTableOfContents ?? this.showTableOfContents,
      allowRemoteImages: allowRemoteImages ?? this.allowRemoteImages,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'theme': theme.storageValue,
    'profile': profile.storageValue,
    'colorMode': colorMode.storageValue,
    'textScale': textScale,
    'showTableOfContents': showTableOfContents,
    'allowRemoteImages': allowRemoteImages,
  };

  factory MarkdownPreviewPreferences.fromJson(Map<String, Object?> json) {
    final rawTextScale = json['textScale'];
    final rawTheme = json['theme'];
    final rawProfile = json['profile'];
    final rawColorMode = json['colorMode'];
    final textScale = rawTextScale is num
        ? rawTextScale.toDouble().clamp(minimumTextScale, maximumTextScale)
        : defaults.textScale;
    return MarkdownPreviewPreferences(
      theme:
          MarkdownPreviewTheme.tryParse(rawTheme is String ? rawTheme : null) ??
          defaults.theme,
      profile:
          MarkdownPreviewProfile.tryParse(
            rawProfile is String ? rawProfile : null,
          ) ??
          defaults.profile,
      colorMode:
          MarkdownPreviewColorMode.tryParse(
            rawColorMode is String ? rawColorMode : null,
          ) ??
          defaults.colorMode,
      textScale: textScale,
      showTableOfContents: _boolOrDefault(
        json['showTableOfContents'],
        defaults.showTableOfContents,
      ),
      allowRemoteImages: _boolOrDefault(
        json['allowRemoteImages'],
        defaults.allowRemoteImages,
      ),
    );
  }

  static bool _boolOrDefault(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  @override
  bool operator ==(Object other) =>
      other is MarkdownPreviewPreferences &&
      theme == other.theme &&
      profile == other.profile &&
      colorMode == other.colorMode &&
      textScale == other.textScale &&
      showTableOfContents == other.showTableOfContents &&
      allowRemoteImages == other.allowRemoteImages;

  @override
  int get hashCode => Object.hash(
    theme,
    profile,
    colorMode,
    textScale,
    showTableOfContents,
    allowRemoteImages,
  );
}
