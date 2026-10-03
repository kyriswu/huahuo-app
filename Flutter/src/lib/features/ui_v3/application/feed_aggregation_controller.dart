// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../data/feed_aggregation_repository.dart';
import '../domain/feed_item_models.dart';
import '../domain/profile_activity_models.dart';
import '../domain/ui_v3_models.dart';
import 'feed_aggregation_task_controller.dart';
import 'knowledge_library_controller.dart';

export 'feed_aggregation_task_controller.dart'
    show FeedAggregationPhase, FeedAggregationTaskNotice;
import 'profile_hub_controller.dart';

// resident-provider: Preserves the feed aggregation controller state machine across route transitions.
final feedAggregationControllerProvider =
    ChangeNotifierProvider<FeedAggregationController>((ref) {
      return FeedAggregationController(
        library: ref.watch(knowledgeLibraryControllerProvider.notifier),
        profileHub: ref.read(profileHubControllerProvider),
        repository: ref.read(feedAggregationRepositoryProvider),
        topicCollisionRuns: ref.read(topicCollisionRunPortProvider),
        foregroundDuration: const Duration(milliseconds: 2400),
      );
    });

final class FeedAggregationController extends ChangeNotifier {
  FeedAggregationController({
    required KnowledgeLibraryController library,
    required ProfileHubController profileHub,
    required FeedAggregationRepository repository,
    TopicCollisionRunPort? topicCollisionRuns,
    AppPreferencesDao? preferences,
    String userScope = 'anonymous',
    String? Function()? workspaceId,
    bool Function()? workspaceReady,
    Duration foregroundDuration = Duration.zero,
    Duration productionPollInterval = const Duration(seconds: 2),
    DiagnosticLogger? diagnosticLogger,
    Random? random,
    DateTime Function()? now,
  }) : _library = library,
       _profileHub = profileHub,
       _repository = repository,
       _foregroundDuration = foregroundDuration,
       _random = random ?? Random(),
       _now = now ?? DateTime.now {
    final port = topicCollisionRuns;
    _production = port == null || port is UnavailableTopicCollisionRunPort
        ? null
        : FeedAggregationTaskController(
            library: library,
            profileHub: profileHub,
            remote: port,
            preferences: preferences,
            userScope: userScope,
            workspaceId: workspaceId ?? _noWorkspace,
            workspaceReady: workspaceReady ?? _workspaceUnavailable,
            diagnosticLogger: diagnosticLogger,
            random: random,
            now: now,
            pollInterval: productionPollInterval,
          );
    _production?.addListener(notifyListeners);
  }

  final KnowledgeLibraryController _library;
  final ProfileHubController _profileHub;
  final FeedAggregationRepository _repository;
  late final FeedAggregationTaskController? _production;
  bool _disposed = false;
  final Duration _foregroundDuration;
  final Random _random;
  final DateTime Function() _now;
  final Set<String> _selectedNoteIds = <String>{};

  FeedAggregationStatus _status = FeedAggregationStatus.idle;
  String? _hotspotNoteId;
  double _progress = 0;
  String? _generatedNoteId;
  String? _errorCode;
  bool _hasGeneratedOnce = false;
  int _generationToken = 0;
  Object? _selectionOwner;
  String? _taskId;
  String? _completedTaskId;
  DateTime? _taskCreatedAt;
  final List<FeedAggregationTaskNotice> _settledNotices = [];

  FeedAggregationStatus get status => _production?.status ?? _status;
  Set<String> get selectedNoteIds =>
      _production?.selectedNoteIds ??
      Set<String>.unmodifiable(_selectedNoteIds);
  List<V3FeedItem> get selectedNotes =>
      _production?.selectedNotes ??
      selectedNoteIds
          .map(_library.noteForId)
          .whereType<V3FeedItem>()
          .toList(growable: false);
  String? get hotspotNoteId => _hotspotNoteId;
  double get progress => _production == null
      ? _progress
      : _production.run == null
      ? 0
      : 1;
  String? get generatedNoteId =>
      _production == null ? _generatedNoteId : _production.generatedNoteId;
  V3FeedItem? get generatedNote => _production == null
      ? (_generatedNoteId == null
            ? null
            : _library.noteForId(_generatedNoteId!))
      : _production.generatedNote;
  String? get errorCode =>
      _production == null ? _errorCode : _production.errorCode;
  String? get taskId => _production == null ? _taskId : _production.taskId;
  bool matchesTaskReference(String? reference) =>
      _production?.matchesTaskReference(reference) ??
      (reference != null &&
          reference.isNotEmpty &&
          (reference == _taskId || reference == _completedTaskId));
  String? get completedTaskId =>
      _production == null ? _completedTaskId : _production.completedTaskId;
  DateTime? get taskCreatedAt => _production?.createdAt ?? _taskCreatedAt;
  List<FeedAggregationTaskNotice> get taskNotices {
    if (_production != null) return _production.taskNotices;
    if (_taskId == null ||
        _taskCreatedAt == null ||
        status == FeedAggregationStatus.selecting ||
        (status == FeedAggregationStatus.idle && completedTaskId == null)) {
      return List.unmodifiable(_settledNotices);
    }
    final completed = completedTaskId != null && generatedNote != null;
    return [
      ..._settledNotices,
      FeedAggregationTaskNotice(
        reference: _taskId!,
        runId: _taskId,
        phase: completed
            ? FeedAggregationPhase.succeeded
            : status == FeedAggregationStatus.failed
            ? FeedAggregationPhase.failed
            : FeedAggregationPhase.running,
        title: completed ? '观点聚合完成' : taskTitle,
        message: taskMessage,
        createdAt: _taskCreatedAt!,
        note: completed ? generatedNote : null,
        sources: selectedNotes,
        isCurrent: true,
        errorCode: errorCode,
      ),
    ];
  }

  FeedAggregationTaskNotice? noticeForReference(String? reference) {
    for (final notice in taskNotices) {
      if (notice.matches(reference)) return notice;
    }
    return null;
  }

  Set<String> completedTaskIdsForNote(String noteId) => {
    for (final notice in taskNotices)
      if (notice.phase == FeedAggregationPhase.succeeded &&
          notice.note?.id == noteId)
        notice.runId ?? notice.reference,
  };
  bool get hasGeneratedOnce => _production == null
      ? _hasGeneratedOnce
      : _production.completedTaskId != null;
  TopicCollisionRun? get productionRun => _production?.run;
  FeedAggregationPhase? get productionPhase => _production?.phase;
  bool get usesProductionRun => _production != null;
  bool get hasUnresolvedTask =>
      _production?.hasUnresolvedTask ??
      (_status == FeedAggregationStatus.aggregating ||
          _status == FeedAggregationStatus.backgroundPending);
  bool get canResumeTask => _production?.canResume ?? false;
  bool get requiresAttention => _production?.requiresAttention ?? false;
  String get taskTitle =>
      _production?.title ??
      (status == FeedAggregationStatus.failed ? '观点聚合失败' : '观点聚合中...');
  String get taskMessage =>
      _production?.message ??
      (status == FeedAggregationStatus.failed
          ? '未能生成新的观点，请重试。'
          : '正在梳理笔记之间的关系并生成新的观点。');
  String get recoveryLabel => _production?.recoveryLabel ?? '重试';
  bool get canConfirm =>
      _production?.canConfirm ??
      (_status == FeedAggregationStatus.selecting &&
          _selectedNoteIds.length == 4 &&
          _selectedNoteIds.every(
            (id) => normalNotes.any((note) => note.id == id),
          ) &&
          _hotspotNoteId != null);
  bool get canReshuffle =>
      _production?.canReshuffle ??
      (_status == FeedAggregationStatus.selecting && normalNotes.length > 4);
  List<V3FeedItem> get normalNotes =>
      _production?.eligibleNotes ??
      (_library.allDepositedNotes
          .where(
            (note) => !note.isHotspot && !note.id.startsWith('aggregation-'),
          )
          .toList()
        ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt)));

  bool ownsSelection(Object owner) =>
      _production?.ownsSelection(owner) ??
      (!_disposed && identical(_selectionOwner, owner));

  Future<bool> prepareSelection({Object? owner}) async {
    if (_production != null) return _production.prepareSelection(owner: owner);
    final prepared = startSelection();
    if (prepared) _selectionOwner = owner;
    return prepared;
  }

  Future<void> resumeTask() async => _production?.retry();
  void attachPollingRuntime({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
  }) => _production?.attachPollingRuntime(
    orchestrator: orchestrator,
    activityMetrics: activityMetrics,
  );
  void resumeProductionPolling() => _production?.resume();
  void pauseProductionPolling() => _production?.pause();

  List<V3FeedItem> get hotspotNotes =>
      _library.notes.where((note) => note.isHotspot).toList(growable: false)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  V3FeedItem? get hotspotNote =>
      _hotspotNoteId == null ? null : _library.noteForId(_hotspotNoteId!);

  bool startSelection() {
    if (_production != null) return _production.startSelection();
    if (_disposed ||
        hasUnresolvedTask ||
        _status == FeedAggregationStatus.selecting) {
      return false;
    }
    _selectionOwner = null;
    final normals = normalNotes;
    if (normals.length < 4) {
      _errorCode = 'AGGREGATION_NOT_ENOUGH_DEPOSITED_ASSETS';
      _status = FeedAggregationStatus.idle;
      notifyListeners();
      return false;
    }
    final hotspots = hotspotNotes;
    if (hotspots.isEmpty) {
      _errorCode = 'AGGREGATION_HOTSPOT_UNAVAILABLE';
      _status = FeedAggregationStatus.idle;
      notifyListeners();
      return false;
    }
    if (_status == FeedAggregationStatus.succeeded ||
        _status == FeedAggregationStatus.failed ||
        (_status == FeedAggregationStatus.idle && _completedTaskId != null)) {
      final notice = noticeForReference(_taskId);
      if (notice != null) {
        _settledNotices.add(
          FeedAggregationTaskNotice(
            reference: notice.reference,
            runId: notice.runId,
            phase: notice.phase,
            title: notice.title,
            message: notice.message,
            createdAt: notice.createdAt,
            note: notice.note,
            sources: notice.sources,
            isCurrent: false,
            errorCode: notice.errorCode,
          ),
        );
      }
    }
    _generatedNoteId = null;
    _completedTaskId = null;
    _hotspotNoteId = hotspots.first.id;
    _selectBatch();
    _status = FeedAggregationStatus.selecting;
    _taskCreatedAt = _now();
    _taskId =
        'aggregation-${_taskCreatedAt!.microsecondsSinceEpoch}-${++_generationToken}';
    _errorCode = null;
    _progress = 0;
    notifyListeners();
    return true;
  }

  void toggleNormalNote(String noteId) {
    if (_production != null) {
      _production.toggleNote(noteId);
      return;
    }
    if (_status != FeedAggregationStatus.selecting) return;
    if (!normalNotes.any((note) => note.id == noteId)) return;
    if (!_selectedNoteIds.add(noteId)) _selectedNoteIds.remove(noteId);
    notifyListeners();
  }

  void reshuffle() {
    if (_production != null) {
      _production.reshuffle();
      return;
    }
    if (_status != FeedAggregationStatus.selecting || !canReshuffle) return;
    _selectBatch();
    notifyListeners();
  }

  Future<V3FeedItem?> confirm() async {
    if (_production != null) return _production.confirm();
    if (!canConfirm) return null;
    final normalSelection = _selectedNoteIds
        .map(_library.noteForId)
        .whereType<V3FeedItem>()
        .where(
          (note) => normalNotes.any((candidate) => candidate.id == note.id),
        )
        .toList(growable: false);
    final hotspot = hotspotNote;
    if (normalSelection.length != 4 || hotspot == null) return null;

    final token = ++_generationToken;
    _status = FeedAggregationStatus.aggregating;
    _progress = 0;
    _errorCode = null;
    notifyListeners();
    try {
      if (_foregroundDuration > Duration.zero) {
        await Future<void>.delayed(_foregroundDuration);
      }
      if (token != _generationToken) return null;
      _progress = 1;
      _status = FeedAggregationStatus.backgroundPending;
      notifyListeners();
      final generated = await _repository.aggregate(
        normalNotes: normalSelection,
        hotspotNote: hotspot,
      );
      if (token != _generationToken) return null;
      _library.updateNote(generated);
      if (!await _library.flushPersistenceResult()) {
        throw StateError('FEED_AGGREGATION_PERSISTENCE_FAILED');
      }
      if (token != _generationToken) return null;
      _progress = 1;
      _status = FeedAggregationStatus.succeeded;
      _generatedNoteId = generated.id;
      _completedTaskId = _taskId;
      _hasGeneratedOnce = true;
      _profileHub.recordActivity(
        V3ProfileActivity(
          id: 'aggregation-${generated.id}',
          occurredAt: generated.createdAt,
          type: V3ProfileActivityType.summary,
          title: generated.title,
          feedItemId: generated.id,
          route:
              '/v3/feed/items/${Uri.encodeComponent(generated.id)}?stage=summary',
        ),
      );
      notifyListeners();
      return generated;
    } catch (_) {
      if (token != _generationToken) return null;
      _status = FeedAggregationStatus.failed;
      _errorCode = 'FEED_AGGREGATION_FAILED';
      notifyListeners();
      return null;
    }
  }

  void adjustMaterials() {
    if (usesProductionRun) {
      startSelection();
      return;
    }
    if (!_hasGeneratedOnce || _selectedNoteIds.isEmpty) return;
    _status = FeedAggregationStatus.selecting;
    _progress = 0;
    _errorCode = null;
    notifyListeners();
  }

  AggregationAgentLaunchRequest? agentRequestFor(AggregationAgentKind kind) {
    final hotspotId = _hotspotNoteId;
    if (_status != FeedAggregationStatus.succeeded ||
        _selectedNoteIds.length != 4 ||
        hotspotId == null) {
      return null;
    }
    return AggregationAgentLaunchRequest(
      kind: kind,
      noteIds: _selectedNoteIds,
      hotspotId: hotspotId,
    );
  }

  void dismissCompletion() {
    if (_production != null) {
      _production.dismissCompletion();
      return;
    }
    if (_status != FeedAggregationStatus.succeeded) return;
    _status = FeedAggregationStatus.idle;
    _progress = 0;
    notifyListeners();
  }

  void cancelSelection({Object? owner}) {
    if (_production != null) {
      _production.cancelSelection(owner: owner);
      return;
    }
    if (_disposed ||
        _status != FeedAggregationStatus.selecting ||
        (owner != null && !ownsSelection(owner))) {
      return;
    }
    _selectionOwner = null;
    _generationToken++;
    _status = FeedAggregationStatus.idle;
    _selectedNoteIds.clear();
    _hotspotNoteId = null;
    _progress = 0;
    _errorCode = null;
    notifyListeners();
  }

  void clearError() {
    if (_production != null) return;
    if (_errorCode == null) return;
    _errorCode = null;
    notifyListeners();
  }

  void _selectBatch() {
    final notes = normalNotes.toList(growable: false)..shuffle(_random);
    _selectedNoteIds
      ..clear()
      ..addAll(notes.take(4).map((note) => note.id));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generationToken++;
    _production?.removeListener(notifyListeners);
    _production?.dispose();
    super.dispose();
  }
}

String? _noWorkspace() => null;
bool _workspaceUnavailable() => false;
