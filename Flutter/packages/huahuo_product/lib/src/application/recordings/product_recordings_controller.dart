import '../../domain/product_result.dart';
import '../../domain/recordings/product_recording.dart';

enum ProductRecordingsStatus { idle, loading, empty, ready, failure }

enum ProductRecordingDetailStatus { idle, loading, ready, failure }

typedef ProductRecordingsListener = void Function();
typedef ProductRecordingsKeyFactory = String Function(String action);

final class ProductRecordingsState {
  const ProductRecordingsState({
    required this.workspaceId,
    required this.status,
    required this.items,
    required this.selectedId,
    required this.detailStatus,
    required this.detail,
    required this.speakerPanel,
    required this.busyAction,
    required this.errorCode,
    required this.errorMessage,
    required this.retryable,
  });

  const ProductRecordingsState.idle()
    : this(
        workspaceId: null,
        status: ProductRecordingsStatus.idle,
        items: const <ProductRecording>[],
        selectedId: null,
        detailStatus: ProductRecordingDetailStatus.idle,
        detail: null,
        speakerPanel: null,
        busyAction: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      );

  final String? workspaceId;
  final ProductRecordingsStatus status;
  final List<ProductRecording> items;
  final String? selectedId;
  final ProductRecordingDetailStatus detailStatus;
  final ProductRecordingDetail? detail;
  final ProductSpeakerPanel? speakerPanel;
  final String? busyAction;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  ProductRecordingsState copyWith({
    String? workspaceId,
    ProductRecordingsStatus? status,
    List<ProductRecording>? items,
    String? selectedId,
    ProductRecordingDetailStatus? detailStatus,
    ProductRecordingDetail? detail,
    ProductSpeakerPanel? speakerPanel,
    String? busyAction,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearSelection = false,
    bool clearDetail = false,
    bool clearSpeakerPanel = false,
    bool clearBusy = false,
    bool clearError = false,
  }) => ProductRecordingsState(
    workspaceId: workspaceId ?? this.workspaceId,
    status: status ?? this.status,
    items: List<ProductRecording>.unmodifiable(items ?? this.items),
    selectedId: clearSelection ? null : selectedId ?? this.selectedId,
    detailStatus: detailStatus ?? this.detailStatus,
    detail: clearDetail ? null : detail ?? this.detail,
    speakerPanel: clearSpeakerPanel ? null : speakerPanel ?? this.speakerPanel,
    busyAction: clearBusy ? null : busyAction ?? this.busyAction,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}

final class ProductRecordingsController {
  ProductRecordingsController(
    this._repository, {
    ProductRecordingsKeyFactory? keyFactory,
  }) : _keyFactory = keyFactory ?? _defaultKey;

  final ProductRecordingsRepository _repository;
  final ProductRecordingsKeyFactory _keyFactory;
  final Set<ProductRecordingsListener> _listeners = {};
  final Map<String, String> _pendingKeys = {};
  ProductRecordingsState _state = const ProductRecordingsState.idle();
  int _generation = 0;
  int _listSequence = 0;
  int _detailSequence = 0;
  bool _disposed = false;

  ProductRecordingsState get state => _state;

  void addListener(ProductRecordingsListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductRecordingsListener listener) {
    _listeners.remove(listener);
  }

  Future<void> bindWorkspace(String? workspaceId) async {
    final id = workspaceId?.trim();
    if (id == null || id.isEmpty) {
      reset();
      return;
    }
    if (_state.workspaceId == id &&
        _state.status != ProductRecordingsStatus.idle) {
      return;
    }
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _pendingKeys.clear();
    _emit(
      ProductRecordingsState(
        workspaceId: id,
        status: ProductRecordingsStatus.loading,
        items: const [],
        selectedId: null,
        detailStatus: ProductRecordingDetailStatus.idle,
        detail: null,
        speakerPanel: null,
        busyAction: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      ),
    );
    await _loadList(id, _generation);
  }

  Future<void> reload() async {
    final id = _state.workspaceId;
    if (id != null) await _loadList(id, _generation);
  }

  Future<void> select(String recordingId) async {
    final id = recordingId.trim();
    if (id.isEmpty || !_state.items.any((item) => item.id == id)) return;
    final generation = _generation;
    final sequence = ++_detailSequence;
    _emit(
      _state.copyWith(
        selectedId: id,
        detailStatus: ProductRecordingDetailStatus.loading,
        clearDetail: true,
        clearSpeakerPanel: true,
        clearError: true,
      ),
    );
    final result = await _guard(() => _repository.detail(id));
    if (!_acceptDetail(generation, sequence, id)) return;
    final detail = result.data;
    if (!result.isSuccess || detail == null) {
      _detailFailure(result);
      return;
    }
    _emit(
      _state.copyWith(
        detailStatus: ProductRecordingDetailStatus.ready,
        detail: detail,
        clearError: true,
      ),
    );
    if (detail.recording.requiresSpeakerLabels) {
      await _loadSpeakerPanel(id, generation, sequence);
    }
  }

  void resetSelectionForView() {
    _detailSequence++;
    _emit(
      _state.copyWith(
        detailStatus: ProductRecordingDetailStatus.idle,
        clearSelection: true,
        clearDetail: true,
        clearSpeakerPanel: true,
        clearError: true,
      ),
    );
  }

  void updateSpeakerName(String speakerId, String name) {
    final panel = _state.speakerPanel;
    if (panel == null || !panel.speakers.any((item) => item.id == speakerId)) {
      return;
    }
    final names = Map<String, String>.of(panel.names)..[speakerId] = name;
    _emit(_state.copyWith(speakerPanel: panel.copyWith(names: names)));
  }

  void selectSelfSpeaker(String speakerId) {
    final panel = _state.speakerPanel;
    if (panel == null || !panel.speakers.any((item) => item.id == speakerId)) {
      return;
    }
    _emit(
      _state.copyWith(speakerPanel: panel.copyWith(selfSpeakerId: speakerId)),
    );
  }

  Future<bool> saveSpeakerDraft() => _speakerMutation(submit: false);

  Future<bool> submitSpeakerLabels() => _speakerMutation(submit: true);

  Future<bool> retryStage(String stage) async {
    final id = _state.selectedId;
    final normalizedStage = stage.trim();
    if (id == null || normalizedStage.isEmpty || _state.busyAction != null) {
      return false;
    }
    final action = 'retry:$id:$normalizedStage';
    final generation = _generation;
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => _repository.retryStage(
        recordingId: id,
        stage: normalizedStage,
        idempotencyKey: key,
      ),
    );
    if (_disposed || generation != _generation || _state.selectedId != id) {
      return false;
    }
    if (!result.isSuccess) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    _emit(_state.copyWith(clearBusy: true, clearError: true));
    await select(id);
    return true;
  }

  Future<bool> _speakerMutation({required bool submit}) async {
    final panel = _state.speakerPanel;
    if (panel == null ||
        _state.busyAction != null ||
        (submit && !panel.isComplete)) {
      return false;
    }
    final id = panel.recordingId;
    final action = '${submit ? 'submit' : 'draft'}:$id';
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = submit
        ? await _guard(
            () => _repository.submitSpeakerLabels(
              recordingId: id,
              baseAsrTaskVersion: panel.asrTask.version ?? 0,
              names: panel.names,
              selfSpeakerId: panel.selfSpeakerId!,
              idempotencyKey: key,
            ),
          )
        : await _guard(
            () => _repository.saveSpeakerDraft(
              recordingId: id,
              names: panel.names,
              selfSpeakerId: panel.selfSpeakerId,
              idempotencyKey: key,
            ),
          );
    if (_disposed || generation != _generation || _state.selectedId != id) {
      return false;
    }
    if (!result.isSuccess) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    _emit(_state.copyWith(clearBusy: true, clearError: true));
    if (submit) await select(id);
    return true;
  }

  Future<void> _loadList(String workspaceId, int generation) async {
    final sequence = ++_listSequence;
    _emit(
      _state.copyWith(
        status: ProductRecordingsStatus.loading,
        clearError: true,
      ),
    );
    final result = await _guard(() => _repository.list(workspaceId));
    if (_disposed ||
        generation != _generation ||
        sequence != _listSequence ||
        _state.workspaceId != workspaceId) {
      return;
    }
    final items = result.data;
    if (result.isSuccess && items != null) {
      final sorted = List<ProductRecording>.of(items)
        ..sort((left, right) {
          final l = left.recordedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final r = right.recordedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return r.compareTo(l);
        });
      _emit(
        _state.copyWith(
          status: sorted.isEmpty
              ? ProductRecordingsStatus.empty
              : ProductRecordingsStatus.ready,
          items: sorted,
          clearError: true,
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        status: ProductRecordingsStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  Future<void> _loadSpeakerPanel(
    String id,
    int generation,
    int sequence,
  ) async {
    final result = await _guard(() => _repository.speakerPanel(id));
    if (!_acceptDetail(generation, sequence, id)) return;
    final panel = result.data;
    if (result.isSuccess && panel != null) {
      _emit(_state.copyWith(speakerPanel: panel, clearError: true));
    } else {
      _detailFailure(result);
    }
  }

  bool _acceptDetail(int generation, int sequence, String id) =>
      !_disposed &&
      generation == _generation &&
      sequence == _detailSequence &&
      _state.selectedId == id;

  void _detailFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        detailStatus: ProductRecordingDetailStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void _mutationFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        clearBusy: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  Future<ProductResult<T>> _guard<T>(
    Future<ProductResult<T>> Function() action,
  ) async {
    try {
      return await action();
    } on Object {
      return ProductResult<T>.failure(
        code: 'PRODUCT_RECORDINGS_UNEXPECTED',
        message: '录音服务暂时不可用',
        retryable: true,
      );
    }
  }

  void reset() {
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _pendingKeys.clear();
    _emit(const ProductRecordingsState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
  }

  void _emit(ProductRecordingsState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<ProductRecordingsListener>.of(_listeners)) {
      listener();
    }
  }
}

String _defaultKey(String action) =>
    'recording-$action-${DateTime.now().toUtc().microsecondsSinceEpoch}';
