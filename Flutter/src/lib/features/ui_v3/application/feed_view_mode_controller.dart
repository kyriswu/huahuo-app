import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'knowledge_library_runtime.dart';

// resident-provider: Preserves the workspace session's Feed dimension across route disposal without retaining the graph runtime.
final feedViewModeControllerProvider =
    ChangeNotifierProvider<FeedViewModeController>((ref) {
      ref.watch(knowledgeLibraryCacheScopeProvider);
      return FeedViewModeController();
    });

enum FeedViewMode { notes, sphere }

final class FeedViewModeController extends ChangeNotifier {
  FeedViewMode? _mode;

  FeedViewMode get mode => _mode ?? FeedViewMode.notes;

  void initialize({required bool initiallyShowNotes}) {
    _mode ??= initiallyShowNotes ? FeedViewMode.notes : FeedViewMode.sphere;
  }

  void select(FeedViewMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
  }
}
