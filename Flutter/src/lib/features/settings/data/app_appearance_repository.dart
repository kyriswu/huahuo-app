import '../../../core/database/app_preferences_dao.dart';
import '../domain/app_appearance_preset.dart';

final class AppAppearanceRepository {
  AppAppearanceRepository({
    required AppPreferencesDao dao,
    DateTime Function()? now,
  }) : // The public constructor name intentionally differs from the field.
       // ignore: prefer_initializing_formals
       _dao = dao,
       _now = now ?? DateTime.now;

  static const preferenceKey = 'appearance.preset';
  static const textSizePreferenceKey = 'appearance.text-size';
  static const glassOpacityPreferenceKey = 'appearance.glass-opacity';

  final AppPreferencesDao _dao;
  final DateTime Function() _now;

  AppAppearancePreset loadPreset() {
    final rawValue = _dao.readValue(preferenceKey);
    if (rawValue == null) return AppAppearancePreset.light;
    final parsed = AppAppearancePreset.tryParse(rawValue);
    if (parsed != null) return parsed;
    savePreset(AppAppearancePreset.light);
    return AppAppearancePreset.light;
  }

  void savePreset(AppAppearancePreset preset) {
    _dao.upsertValue(
      preferenceKey: preferenceKey,
      value: preset.wireName,
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }

  AppTextSizePreset loadTextSizePreset() {
    final rawValue = _dao.readValue(textSizePreferenceKey);
    if (rawValue == null) return AppTextSizePreset.percent100;
    final parsed = AppTextSizePreset.tryParse(rawValue);
    if (parsed != null) return parsed;
    saveTextSizePreset(AppTextSizePreset.percent100);
    return AppTextSizePreset.percent100;
  }

  void saveTextSizePreset(AppTextSizePreset preset) {
    _dao.upsertValue(
      preferenceKey: textSizePreferenceKey,
      value: preset.wireName,
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }

  int loadGlassOpacityPercent() {
    final rawValue = _dao.readValue(glassOpacityPreferenceKey);
    final parsed = int.tryParse(rawValue ?? '');
    if (parsed != null && parsed >= 0 && parsed <= 100) return parsed;
    saveGlassOpacityPercent(50);
    return 50;
  }

  void saveGlassOpacityPercent(int percent) {
    final normalized = percent.clamp(0, 100);
    _dao.upsertValue(
      preferenceKey: glassOpacityPreferenceKey,
      value: '$normalized',
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }
}
