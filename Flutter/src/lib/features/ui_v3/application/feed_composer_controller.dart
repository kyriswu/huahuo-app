import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// resident-provider: Preserves the feed composer controller state machine across route transitions.
final feedComposerControllerProvider =
    ChangeNotifierProvider<FeedComposerController>(
      (ref) => FeedComposerController(),
    );

final class FeedComposerController extends ChangeNotifier {
  bool _addMenuOpen = const bool.fromEnvironment('HUAHUO_V3_OPEN_ADD_MENU');
  bool get addMenuOpen => _addMenuOpen;

  void toggleAddMenu() {
    _addMenuOpen = !_addMenuOpen;
    notifyListeners();
  }

  void closeAddMenu() {
    if (!_addMenuOpen) return;
    _addMenuOpen = false;
    notifyListeners();
  }
}
