import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/deep_positioning_repository.dart'
    show
        DeepPositioningRepository,
        InitialPositioningReportSink,
        InitialPositioningFormalReportSink,
        PositioningReportReadPort,
        deepPositioningRepositoryProvider;
import '../domain/deep_positioning_models.dart';

// resident-provider: Preserves the deep positioning controller state machine across route transitions.
final deepPositioningControllerProvider =
    ChangeNotifierProvider<DeepPositioningController>((ref) {
      return DeepPositioningController(
        ref.watch(deepPositioningRepositoryProvider),
      );
    });

final class DeepPositioningController extends ChangeNotifier
    implements
        InitialPositioningReportSink,
        InitialPositioningFormalReportSink {
  DeepPositioningController(this._repository) {
    _restoreReport();
    unawaited(refresh());
  }

  final DeepPositioningRepository _repository;
  DeepPositioningDraft _draft = const DeepPositioningDraft();
  DeepPositioningResult? _result;
  bool _saving = false;
  bool _refreshing = false;
  Future<void>? _refreshInFlight;
  int _successfulRefreshRevision = 0;
  bool _disposed = false;
  String? _errorCode;
  PositioningReportRead _read = const PositioningReportRead(
    PositioningReportOrigin.unavailable,
  );

  PositioningReportRead get reportRead => _read;

  @override
  Future<bool> refreshFormalReport() => refreshForReportPresentation();

  DeepPositioningDraft get draft => _draft;
  DeepPositioningResult? get result => _result;
  bool get saving => _saving;
  bool get refreshing => _refreshing;
  String? get errorCode => _errorCode;
  bool get canSubmit => _draft.isValid && !_saving;
  bool get isDemo => _repository.isDemo;

  void updateIdentity(String value) =>
      _update(_draft.copyWith(identity: value));
  void updateIndustry(String value) =>
      _update(_draft.copyWith(industry: value));
  void updateExpertise(String value) =>
      _update(_draft.copyWith(expertise: value));
  void updateTargetAudience(String value) =>
      _update(_draft.copyWith(targetAudience: value));
  void updateValue(String value) => _update(_draft.copyWith(value: value));
  void updateAccountGoal(String value) =>
      _update(_draft.copyWith(accountGoal: value));
  void updateStories(String value) => _update(_draft.copyWith(stories: value));
  void updateCommonExpressions(String value) =>
      _update(_draft.copyWith(commonExpressions: value));

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    if (_saving) return false;
    _saving = true;
    _errorCode = null;
    notifyListeners();
    try {
      final result = await _repository.saveInitialReport(
        markdown: markdown,
        savedAt: savedAt,
      );
      if (!_disposed) {
        _result = result;
        _saving = false;
        notifyListeners();
      }
      return true;
    } catch (_) {
      if (!_disposed) {
        _saving = false;
        _errorCode = 'DEEP_POSITIONING_INITIAL_REPORT_SAVE_FAILED';
        notifyListeners();
      }
      return false;
    }
  }

  Future<void> refresh() {
    final active = _refreshInFlight;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _performRefresh().whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = operation;
    return operation;
  }

  Future<bool> refreshForReportPresentation() async {
    final active = _refreshInFlight;
    if (active != null) await active;
    final revision = _successfulRefreshRevision;
    await refresh();
    return !_disposed &&
        _successfulRefreshRevision > revision &&
        _result != null;
  }

  Future<void> _performRefresh() async {
    _refreshing = true;
    _read = PositioningReportRead(
      PositioningReportOrigin.unavailable,
      report: _result,
    );
    try {
      final repository = _repository;
      final read = repository is PositioningReportReadPort
          ? await (repository as PositioningReportReadPort).readReport()
          : PositioningReportRead(
              PositioningReportOrigin.unavailable,
              report: await repository.refresh(),
            );
      if (!_disposed) {
        _read = read;
        _result = read.report ?? _result;
        _errorCode = read.errorCode;
        if (read.isRemote && read.report != null)
          _successfulRefreshRevision += 1;
      }
    } catch (_) {
      if (!_disposed) {
        _read = PositioningReportRead(
          PositioningReportOrigin.unavailable,
          report: _result,
          errorCode: 'DEEP_POSITIONING_REFRESH_FAILED',
        );
        _errorCode = 'DEEP_POSITIONING_REFRESH_FAILED';
      }
    } finally {
      if (!_disposed) {
        _refreshing = false;
        notifyListeners();
      }
    }
  }

  Future<bool> save() async {
    if (!canSubmit) return false;
    _saving = true;
    _errorCode = null;
    notifyListeners();
    try {
      final result = await _repository.save(_draft);
      if (_disposed) return false;
      _result = result;
      _saving = false;
      notifyListeners();
      return true;
    } catch (_) {
      if (_disposed) return false;
      _saving = false;
      _errorCode = 'DEEP_POSITIONING_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  Future<bool> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async {
    if (_saving || entries.every((entry) => entry.text.trim().isEmpty)) {
      return false;
    }
    _saving = true;
    _errorCode = null;
    notifyListeners();
    try {
      if (_repository.isDemo) {
        final result = await _repository.saveConversation(
          entries,
          further: further,
        );
        if (_disposed) return false;
        _result = result;
      } else {
        await refresh();
        if (_disposed) return false;
        _saving = false;
        notifyListeners();
        return false;
      }
      _saving = false;
      notifyListeners();
      return true;
    } catch (_) {
      if (_disposed) return false;
      _saving = false;
      _errorCode = 'DEEP_POSITIONING_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  void clearResult() {
    if (_result == null && _errorCode == null) return;
    _result = null;
    _errorCode = null;
    notifyListeners();
  }

  void _restoreReport() {
    try {
      _result = _repository.load();
      _errorCode = null;
    } catch (_) {
      _result = null;
      _errorCode = 'DEEP_POSITIONING_RESTORE_FAILED';
    }
  }

  void _update(DeepPositioningDraft draft) {
    _draft = draft;
    _errorCode = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
