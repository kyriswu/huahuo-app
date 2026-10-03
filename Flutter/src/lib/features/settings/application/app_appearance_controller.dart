import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_appearance_repository.dart';
import '../domain/app_appearance_preset.dart';

// resident-provider: Shares one account-scoped app appearance repository identity across dependent controllers.
final appAppearanceRepositoryProvider = Provider<AppAppearanceRepository?>(
  (ref) => null,
);

// resident-provider: Preserves the app appearance controller state machine across route transitions.
final appAppearanceControllerProvider =
    ChangeNotifierProvider<AppAppearanceController>((ref) {
      final controller = AppAppearanceController(
        repository: ref.watch(appAppearanceRepositoryProvider),
      );
      controller.restore();
      return controller;
    });

final class AppAppearanceController extends ChangeNotifier {
  AppAppearanceController({AppAppearanceRepository? repository})
    : // The public constructor name intentionally differs from the field.
      // ignore: prefer_initializing_formals
      _repository = repository;

  final AppAppearanceRepository? _repository;
  AppAppearancePreset _preset = AppAppearancePreset.light;
  AppTextSizePreset _textSizePreset = AppTextSizePreset.percent100;
  String? _errorCode;
  bool _restored = false;

  AppAppearancePreset get preset => _preset;
  AppTextSizePreset get textSizePreset => _textSizePreset;
  int get glassOpacityPercent => 50;
  String? get errorCode => _errorCode;
  bool get restored => _restored;

  ThemeMode get themeMode => switch (_preset) {
    AppAppearancePreset.system ||
    AppAppearancePreset.mistBlue ||
    AppAppearancePreset.pineGreen ||
    AppAppearancePreset.warmGold ||
    AppAppearancePreset.sakura ||
    AppAppearancePreset.aurora => ThemeMode.system,
    AppAppearancePreset.dark => ThemeMode.dark,
    AppAppearancePreset.light => ThemeMode.light,
  };

  void restore() {
    try {
      _preset = _repository?.loadPreset() ?? AppAppearancePreset.light;
      _textSizePreset =
          _repository?.loadTextSizePreset() ?? AppTextSizePreset.percent100;
      _errorCode = null;
    } catch (_) {
      _preset = AppAppearancePreset.light;
      _textSizePreset = AppTextSizePreset.percent100;
      _errorCode = 'APP_APPEARANCE_RESTORE_FAILED';
    }
    _restored = true;
    notifyListeners();
  }

  bool selectPreset(AppAppearancePreset preset) {
    final canonical = preset.canonical;
    if (canonical == _preset && _errorCode == null) return true;
    try {
      _repository?.savePreset(canonical);
      _preset = canonical;
      _errorCode = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorCode = 'APP_APPEARANCE_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  bool selectTextSizePreset(AppTextSizePreset preset) {
    if (preset == _textSizePreset && _errorCode == null) return true;
    try {
      _repository?.saveTextSizePreset(preset);
      _textSizePreset = preset;
      _errorCode = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorCode = 'APP_TEXT_SIZE_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }
}
