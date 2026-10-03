import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// resident-provider: Preserves the recording library ui controller state machine across route transitions.
final recordingLibraryUiControllerProvider =
    ChangeNotifierProvider<RecordingLibraryUiController>((ref) {
      return RecordingLibraryUiController();
    });

enum V3RecordingLibraryTab {
  local('local', '本地录音'),
  device('device', '录音卡文件');

  const V3RecordingLibraryTab(this.routeValue, this.label);

  final String routeValue;
  final String label;

  static V3RecordingLibraryTab fromRoute(String? value) =>
      value == device.routeValue ? device : local;
}

final class RecordingLibraryUiController extends ChangeNotifier {
  bool _batchMode = false;
  V3RecordingLibraryTab _recordingTab = V3RecordingLibraryTab.local;

  bool get batchMode => _batchMode;
  V3RecordingLibraryTab get recordingTab => _recordingTab;

  void setRecordingTab(V3RecordingLibraryTab value) {
    if (_recordingTab == value) return;
    _recordingTab = value;
    _batchMode = false;
    notifyListeners();
  }

  void setBatchMode(bool value) {
    if (_batchMode == value) return;
    _batchMode = value;
    notifyListeners();
  }

  void toggleBatchMode() => setBatchMode(!_batchMode);

  void reset({V3RecordingLibraryTab tab = V3RecordingLibraryTab.local}) {
    if (_recordingTab == tab && !_batchMode) {
      return;
    }
    _recordingTab = tab;
    _batchMode = false;
    notifyListeners();
  }
}
