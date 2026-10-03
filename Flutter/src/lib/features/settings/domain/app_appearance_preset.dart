enum AppAppearancePreset {
  system,
  light,
  dark,
  mistBlue,
  pineGreen,
  warmGold,
  sakura,
  aurora;

  static const supportedValues = AppAppearancePreset.values;

  AppAppearancePreset get canonical => this;

  String get wireName => switch (this) {
    AppAppearancePreset.system => 'system',
    AppAppearancePreset.light => 'light',
    AppAppearancePreset.dark => 'dark',
    AppAppearancePreset.mistBlue => 'mist-blue',
    AppAppearancePreset.pineGreen => 'pine-green',
    AppAppearancePreset.warmGold => 'warm-gold',
    AppAppearancePreset.sakura => 'sakura',
    AppAppearancePreset.aurora => 'aurora',
  };

  String get label => switch (this) {
    AppAppearancePreset.system => '跟随系统',
    AppAppearancePreset.light => '明亮',
    AppAppearancePreset.dark => '暗黑',
    AppAppearancePreset.mistBlue => '雾蓝',
    AppAppearancePreset.pineGreen => '松绿',
    AppAppearancePreset.warmGold => '暖金',
    AppAppearancePreset.sakura => '绯樱',
    AppAppearancePreset.aurora => '极光',
  };

  static AppAppearancePreset? tryParse(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    for (final preset in AppAppearancePreset.values) {
      if (preset.wireName == normalized) return preset;
    }
    return null;
  }
}

enum AppTextSizePreset {
  percent80(0.80, '80%'),
  percent90(0.90, '90%'),
  percent100(1.00, '100%'),
  percent110(1.10, '110%'),
  percent120(1.20, '120%'),
  percent130(1.30, '130%');

  const AppTextSizePreset(this.factor, this.label);

  final double factor;
  final String label;

  String get wireName => switch (this) {
    AppTextSizePreset.percent80 => '80',
    AppTextSizePreset.percent90 => '90',
    AppTextSizePreset.percent100 => '100',
    AppTextSizePreset.percent110 => '110',
    AppTextSizePreset.percent120 => '120',
    AppTextSizePreset.percent130 => '130',
  };

  static AppTextSizePreset? tryParse(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    for (final preset in values) {
      if (preset.wireName == normalized) return preset;
    }
    return null;
  }
}
