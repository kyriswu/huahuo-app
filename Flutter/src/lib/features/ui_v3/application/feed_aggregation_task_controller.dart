import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../data/feed_aggregation_repository.dart';
import '../domain/feed_item_models.dart';
import '../domain/profile_activity_models.dart';
import '../domain/ui_v3_models.dart';
import 'knowledge_library_controller.dart';
import 'profile_hub_controller.dart';

enum FeedAggregationPhase {
  idle,
  preparing,
  selecting,
  submitting,
  submissionUncertain,
  restoring,
  queued,
  leased,
  admitting,
  running,
  retryWaiting,
  syncingResult,
  succeeded,
  failed,
  blocked,
}

final class FeedAggregationTaskController extends ChangeNotifier {
  factory FeedAggregationTaskController({
    required KnowledgeLibraryController library,
    required ProfileHubController profileHub,
    required TopicCollisionRunPort remote,
    required AppPreferencesDao? preferences,
    required String userScope,
    required String? Function() workspaceId,
    required bool Function() workspaceReady,
    DiagnosticLogger? diagnosticLogger,
    Random? random,
    DateTime Function()? now,
    Duration pollInterval = const Duration(seconds: 2),
    Duration requestTimeout = const Duration(seconds: 30),
    int maxReadFailures = 5,
    int maxOutputReads = 10,
    Duration maxForegroundWait = const Duration(minutes: 10),
  }) => FeedAggregationTaskController._(
    library,
    profileHub,
    remote,
    preferences,
    userScope,
    workspaceId,
    workspaceReady,
    diagnosticLogger,
    random ?? Random.secure(),
    now ?? DateTime.now,
    pollInterval,
    requestTimeout,
    maxReadFailures,
    maxOutputReads,
    maxForegroundWait,
  );

  FeedAggregationTaskController._(
    this._library,
    this._profileHub,
    this._remote,
    this._preferences,
    this._userScope,
    this._workspaceId,
    this._workspaceReady,
    this._logger,
    this._random,
    this._now,
    this.pollInterval,
    this.requestTimeout,
    this.maxReadFailures,
    this.maxOutputReads,
    this.maxForegroundWait,
  ) {
    if (pollInterval <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxReadFailures < 1 ||
        maxOutputReads < 1 ||
        maxForegroundWait <= Duration.zero) {
      throw ArgumentError(
        'Aggregation retry and timeout budgets must be positive',
      );
    }
    _library.addListener(_handleLibraryChanged);
    _restore();
  }

  final KnowledgeLibraryController _library;
  final ProfileHubController _profileHub;
  final TopicCollisionRunPort _remote;
  final AppPreferencesDao? _preferences;
  final String _userScope;
  final String? Function() _workspaceId;
  final bool Function() _workspaceReady;
  final DiagnosticLogger? _logger;
  final Random _random;
  final DateTime Function() _now;
  final Duration pollInterval;
  final Duration requestTimeout;
  final int maxReadFailures;
  final int maxOutputReads;
  final Duration maxForegroundWait;

  FeedAggregationPhase _phase = FeedAggregationPhase.idle;
  List<_AggregationSource> _sources = const [];
  TopicCollisionRun? _run;
  String? _workspace;
  String? _initializedWorkspace;
  String? _idempotencyKey;
  DateTime? _createdAt;
  Timer? _foregroundWaitTimer;
  Object? _selectionOwner;
  String? _errorCode;
  String? _traceId;
  String? _lastObservedRunId;
  String? _lastPersisted;
  String? _generatedNoteId;
  String? _publishedOutputNoteId;
  bool _dismissed = false;
  bool _busy = false;
  bool _polling = false;
  bool _paused = false;
  bool _disposed = false;
  bool _storageBlocked = false;
  bool _unreadable = false;
  int _generation = 0;
  int _readFailures = 0;
  int _outputReads = 0;
  OrchestratedPoller? _poller;
  final Map<String, Map<String, Object?>> _settledTasks = {};

  List<FeedAggregationTaskNotice> get taskNotices {
    if (_unreadable ||
        (_workspace != null && _workspace != _workspaceId()?.trim())) {
      return const [];
    }
    final notices = <FeedAggregationTaskNotice>[];
    for (final record in _settledTasks.values) {
      final reference = record['reference']! as String;
      if (reference == (_idempotencyKey ?? taskId)) continue;
      final savedRun = record['run'] == null
          ? null
          : TopicCollisionRun.fromJson(
              Map<String, Object?>.from(record['run']! as Map),
            );
      final successful = record['phase'] == 'succeeded';
      final output = successful ? _outputFor(savedRun?.outputNoteId) : null;
      final code = successful
          ? output == null
                ? 'AGGREGATION_OUTPUT_UNAVAILABLE'
                : null
          : record['errorCode'] as String?;
      notices.add(
        FeedAggregationTaskNotice(
          reference: reference,
          runId: savedRun?.topicCollisionRunId,
          phase: successful
              ? output == null
                    ? FeedAggregationPhase.blocked
                    : FeedAggregationPhase.succeeded
              : FeedAggregationPhase.failed,
          title: successful
              ? output == null
                    ? '聚合结果暂不可用'
                    : '观点聚合完成'
              : '观点聚合未完成',
          message: successful && output == null
              ? '原结果笔记暂时不可读取，请返回资产刷新并核对是否已删除。不会重新生成。'
              : code == null
              ? successful
                    ? '结果已同步，可查看生成的笔记。'
                    : '本次任务未完成，可以重新选择笔记。'
              : _errorMessage(code),
          createdAt: DateTime.parse(record['createdAt']! as String),
          errorCode: code,
          note: output,
          sources: (record['sources']! as List)
              .map((value) {
                final source = _AggregationSource.fromJson(value);
                return V3FeedItem(
                  id: source.localId,
                  remoteNoteId: source.noteId,
                  title: source.title,
                  source: V3MaterialSource.note,
                  rawBody: '',
                  createdAt: DateTime.parse(record['createdAt']! as String),
                );
              })
              .toList(growable: false),
          isCurrent: false,
        ),
      );
    }
    if (taskId != null &&
        _createdAt != null &&
        phase != FeedAggregationPhase.preparing &&
        phase != FeedAggregationPhase.selecting) {
      final completed = completedTaskId != null && generatedNote != null;
      final unavailable =
          phase == FeedAggregationPhase.idle &&
          _run?.isSuccessful == true &&
          !completed;
      notices.add(
        FeedAggregationTaskNotice(
          reference: _idempotencyKey ?? taskId!,
          runId: _run?.topicCollisionRunId,
          phase: completed
              ? FeedAggregationPhase.succeeded
              : unavailable
              ? FeedAggregationPhase.blocked
              : phase,
          title: completed
              ? '观点聚合完成'
              : unavailable
              ? '聚合结果暂不可用'
              : title,
          message: completed
              ? '结果已同步，可查看生成的笔记。'
              : unavailable
              ? _errorMessage('AGGREGATION_OUTPUT_UNAVAILABLE')
              : message,
          createdAt: _createdAt!,
          errorCode: unavailable
              ? 'AGGREGATION_OUTPUT_UNAVAILABLE'
              : _errorCode,
          note: completed ? generatedNote : null,
          sources: selectedNotes,
          isCurrent: true,
        ),
      );
    }
    return List.unmodifiable(notices);
  }

  V3FeedItem? _outputFor(String? remoteId) {
    if (remoteId == null) return null;
    for (final note in _library.notes) {
      if (_isReadableOutput(note, remoteId)) {
        return note;
      }
    }
    return null;
  }

  FeedAggregationPhase get phase =>
      _phase == FeedAggregationPhase.succeeded && _generatedNoteId == null
      ? FeedAggregationPhase.syncingResult
      : _phase;
  TopicCollisionRun? get run => _run;
  String? get errorCode => _errorCode;
  String? get taskId => _run?.topicCollisionRunId ?? _idempotencyKey;
  bool matchesTaskReference(String? reference) =>
      reference != null &&
      reference.isNotEmpty &&
      (reference == _idempotencyKey || reference == _run?.topicCollisionRunId);
  DateTime? get createdAt => _createdAt;
  String? get generatedNoteId => _generatedNoteId;
  V3FeedItem? get generatedNote {
    final note = _generatedNoteId == null
        ? null
        : _library.noteForId(_generatedNoteId!);
    return note != null && _isReadableOutput(note, _run?.outputNoteId)
        ? note
        : null;
  }

  bool _isReadableOutput(V3FeedItem note, String? remoteId) =>
      remoteId != null &&
      note.remoteNoteId == remoteId &&
      note.syncState == NoteSyncState.synced &&
      note.rawBody.trim().isNotEmpty;

  String? get completedTaskId =>
      generatedNote == null ||
          _storageBlocked ||
          (_phase != FeedAggregationPhase.succeeded &&
              _phase != FeedAggregationPhase.idle)
      ? null
      : _run?.topicCollisionRunId;
  bool get busy => _busy || _polling;
  Set<String> get selectedNoteIds =>
      Set.unmodifiable(_sources.map((source) => source.localId));
  List<V3FeedItem> get selectedNotes => List.unmodifiable(
    _sources.map(
      (source) =>
          _library.noteForId(source.localId)?.copyWith(title: source.title) ??
          V3FeedItem(
            id: source.localId,
            remoteNoteId: source.noteId,
            title: source.title,
            source: V3MaterialSource.note,
            createdAt: _createdAt ?? _now(),
            rawBody: '',
          ),
    ),
  );

  FeedAggregationStatus get status => switch (phase) {
    FeedAggregationPhase.idle => FeedAggregationStatus.idle,
    FeedAggregationPhase.selecting => FeedAggregationStatus.selecting,
    FeedAggregationPhase.preparing ||
    FeedAggregationPhase.submitting => FeedAggregationStatus.aggregating,
    FeedAggregationPhase.succeeded => FeedAggregationStatus.succeeded,
    FeedAggregationPhase.failed => FeedAggregationStatus.failed,
    _ => FeedAggregationStatus.backgroundPending,
  };

  bool get hasUnresolvedTask =>
      busy ||
      _unreadable ||
      _storageBlocked ||
      (!_hasSettledSuccessfulRun &&
          switch (phase) {
            FeedAggregationPhase.idle ||
            FeedAggregationPhase.selecting ||
            FeedAggregationPhase.succeeded ||
            FeedAggregationPhase.failed => false,
            _ => true,
          });

  bool get _hasSettledSuccessfulRun =>
      !_storageBlocked &&
      _run?.isSuccessful == true &&
      _publishedOutputNoteId != null &&
      _publishedOutputNoteId == _run!.outputNoteId;

  bool get canResume =>
      !busy &&
      (_phase == FeedAggregationPhase.submissionUncertain ||
          _phase == FeedAggregationPhase.blocked) &&
      _errorCode != 'AGGREGATION_IDEMPOTENCY_EXPIRED' &&
      _errorCode != 'IDEMPOTENCY_KEY_CONFLICT';
  bool get requiresAttention =>
      _phase == FeedAggregationPhase.submissionUncertain ||
      _phase == FeedAggregationPhase.blocked;
  bool get canConfirm =>
      !busy &&
      _phase == FeedAggregationPhase.selecting &&
      _ready &&
      _sources.length == 4 &&
      _selectedSourcesAreEligible;
  bool get _selectedSourcesAreEligible {
    final eligible = eligibleNotes;
    return _sources.every(
      (source) => eligible.any(
        (note) =>
            note.id == source.localId && note.remoteNoteId == source.noteId,
      ),
    );
  }

  bool get canReshuffle =>
      !busy &&
      _phase == FeedAggregationPhase.selecting &&
      eligibleNotes.length > 4;
  bool get _ready =>
      _workspaceReady() && _workspaceId()?.trim().isNotEmpty == true;
  bool get _readsPending => switch (phase) {
    FeedAggregationPhase.restoring ||
    FeedAggregationPhase.queued ||
    FeedAggregationPhase.leased ||
    FeedAggregationPhase.admitting ||
    FeedAggregationPhase.running ||
    FeedAggregationPhase.retryWaiting ||
    FeedAggregationPhase.syncingResult => true,
    _ => false,
  };

  List<V3FeedItem> get eligibleNotes {
    final seen = <String>{};
    return _library.allDepositedNotes
        .where(
          (note) =>
              !note.isHotspot &&
              !note.id.startsWith('aggregation-') &&
              note.remoteSourceKind != null &&
              note.remoteSourceKind != 'topic_collision' &&
              note.syncState == NoteSyncState.synced &&
              _validId(note.remoteNoteId) &&
              note.rawPartRevisionId?.isNotEmpty == true &&
              note.rawBody.trim().isNotEmpty &&
              seen.add(note.remoteNoteId!),
        )
        .toList()
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  }

  String get title => switch (phase) {
    FeedAggregationPhase.idle => '观点聚合',
    FeedAggregationPhase.preparing => '正在核对云端笔记',
    FeedAggregationPhase.selecting => '确认聚合来源',
    FeedAggregationPhase.submitting => '正在提交聚合',
    FeedAggregationPhase.submissionUncertain => '聚合受理结果待确认',
    FeedAggregationPhase.restoring => '正在恢复聚合进度',
    FeedAggregationPhase.queued => '聚合任务已排队',
    FeedAggregationPhase.leased => '聚合任务已领取',
    FeedAggregationPhase.admitting => '正在准备聚合任务',
    FeedAggregationPhase.running => '观点聚合中',
    FeedAggregationPhase.retryWaiting => '云端正在等待重试',
    FeedAggregationPhase.syncingResult => '聚合已生成，正在同步',
    FeedAggregationPhase.succeeded => '观点聚合完成',
    FeedAggregationPhase.failed => '观点聚合未完成',
    FeedAggregationPhase.blocked => _storageBlocked ? '聚合进度保存受阻' : '聚合进度待确认',
  };

  String get message {
    if (_errorCode != null) return _errorMessage(_errorCode!);
    return switch (_phase) {
      FeedAggregationPhase.preparing => '正在同步笔记正文与来源信息，只有有效的云端笔记可参与聚合。',
      FeedAggregationPhase.selecting => '将按当前选择的四篇笔记生成新观点，确认前可以换一组。',
      FeedAggregationPhase.submitting =>
        '正在提交固定的四篇来源，请勿重复操作。可以返回其他页面，稍后从消息查看进度。',
      FeedAggregationPhase.submissionUncertain =>
        '尚未确认云端是否受理，请继续确认同一次请求，不会重复创建任务。',
      FeedAggregationPhase.restoring => '正在查询原任务的实际进度，不会重新提交或生成。',
      FeedAggregationPhase.retryWaiting =>
        '服务端将自动重试（${_run?.attempt ?? 0}/${_run?.maxAttempts ?? 3}），无需重新生成。',
      FeedAggregationPhase.syncingResult => '云端已经生成结果，正在读取并保存对应笔记。此时不会重新生成。',
      FeedAggregationPhase.succeeded => '结果已同步，可查看和编辑生成的笔记。',
      FeedAggregationPhase.failed => '本次任务已结束，请重新选择有效笔记后再发起聚合。',
      FeedAggregationPhase.blocked => '任务记录已保留，请继续确认原任务状态。',
      _ => '任务正在云端处理。可以返回其他页面，稍后从消息查看同一任务。',
    };
  }

  String get recoveryLabel => _storageBlocked
      ? '重试保存进度'
      : _run?.isSuccessful == true
      ? '继续同步结果'
      : _run != null
      ? '继续查询任务'
      : '继续确认受理';

  bool ownsSelection(Object owner) =>
      !_disposed && identical(_selectionOwner, owner);

  Future<bool> prepareSelection({Object? owner}) async {
    _restore();
    if (_disposed ||
        busy ||
        hasUnresolvedTask ||
        _phase == FeedAggregationPhase.selecting) {
      return false;
    }
    if (!_ready) {
      _setPhase(FeedAggregationPhase.failed, 'WORKSPACE_NOT_READY');
      return false;
    }
    if (!_checkWorkspace()) return false;
    _clearSettledIntent();
    _selectionOwner = owner;
    _busy = true;
    final generation = ++_generation;
    final workspace = _workspaceId()!.trim();
    _setPhase(FeedAggregationPhase.preparing);
    try {
      final synchronized = await _library
          .reconcileRemoteNotesForChatReference()
          .timeout(requestTimeout);
      if (!_owns(generation, workspace)) return false;
      if (!synchronized) {
        _setPhase(
          FeedAggregationPhase.failed,
          'AGGREGATION_SOURCE_SYNC_FAILED',
        );
        return false;
      }
      final missing = _library.allDepositedNotes
          .where(
            (note) =>
                note.remoteSourceKind == null &&
                note.remoteNoteId != null &&
                note.syncState == NoteSyncState.synced &&
                !note.isHotspot,
          )
          .take(12)
          .toList();
      for (final note in missing) {
        if (eligibleNotes.length >= 8) break;
        final refreshed = await _library
            .refreshRemoteDerivedParts(note.id)
            .timeout(requestTimeout);
        if (!_owns(generation, workspace)) return false;
        if (!refreshed) {
          _setPhase(
            FeedAggregationPhase.failed,
            'AGGREGATION_SOURCE_SYNC_FAILED',
          );
          return false;
        }
      }
      if (eligibleNotes.length < 4 &&
          _library.allDepositedNotes.any(
            (note) =>
                note.remoteSourceKind == null &&
                note.remoteNoteId != null &&
                note.syncState == NoteSyncState.synced &&
                !note.isHotspot,
          )) {
        _setPhase(
          FeedAggregationPhase.failed,
          'AGGREGATION_SOURCE_SYNC_PENDING',
        );
        return false;
      }
      return _selectAvailable(workspace);
    } catch (_) {
      if (_owns(generation, workspace)) {
        _setPhase(
          FeedAggregationPhase.failed,
          'AGGREGATION_SOURCE_SYNC_FAILED',
        );
      }
      return false;
    } finally {
      if (generation == _generation) {
        _busy = false;
        _notify();
      }
    }
  }

  bool startSelection() {
    _restore();
    if (_disposed ||
        busy ||
        hasUnresolvedTask ||
        _phase == FeedAggregationPhase.selecting) {
      return false;
    }
    if (!_ready) {
      _setPhase(FeedAggregationPhase.failed, 'WORKSPACE_NOT_READY');
      return false;
    }
    if (!_checkWorkspace()) return false;
    _generation++;
    _selectionOwner = null;
    return _selectAvailable(_workspaceId()!.trim());
  }

  bool _selectAvailable(String workspace) {
    _clearSettledIntent();
    if (_preferences == null) {
      _workspace = workspace;
      _storageBlocked = true;
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_STORAGE_FAILED');
      return false;
    }
    final candidates = eligibleNotes;
    if (candidates.length < 4) {
      _setPhase(
        FeedAggregationPhase.failed,
        'AGGREGATION_NOT_ENOUGH_DEPOSITED_ASSETS',
      );
      return false;
    }
    _workspace = workspace;
    _run = null;
    _idempotencyKey = null;
    _createdAt = null;
    _generatedNoteId = null;
    _dismissed = false;
    _traceId = null;
    candidates.shuffle(_random);
    _sources = List.unmodifiable(
      candidates.take(4).map(_AggregationSource.fromNote),
    );
    _setPhase(FeedAggregationPhase.selecting);
    return true;
  }

  void _clearSettledIntent() {
    if (taskId != null &&
        _createdAt != null &&
        (_phase == FeedAggregationPhase.failed || _hasSettledSuccessfulRun)) {
      final reference = _idempotencyKey ?? taskId!;
      _settledTasks[reference] = {
        'reference': reference,
        'run': _run?.toJson(),
        'phase': _phase == FeedAggregationPhase.failed ? 'failed' : 'succeeded',
        'createdAt': _createdAt!.toIso8601String(),
        'errorCode': _errorCode,
        'sources': _sources.map((source) => source.toJson()).toList(),
      };
    }
    _run = null;
    _idempotencyKey = null;
    _createdAt = null;
    _generatedNoteId = null;
    _sources = const [];
    _publishedOutputNoteId = null;
    _dismissed = false;
    _traceId = null;
    _readFailures = 0;
    _outputReads = 0;
    _poller?.stop();
    _stopForegroundWait();
  }

  void reshuffle() {
    if (!canReshuffle) return;
    final candidates = eligibleNotes..shuffle(_random);
    final old = selectedNoteIds;
    if (candidates.take(4).every((note) => old.contains(note.id))) {
      final replacement = candidates.indexWhere(
        (note) => !old.contains(note.id),
      );
      final previous = candidates[3];
      candidates[3] = candidates[replacement];
      candidates[replacement] = previous;
    }
    _sources = List.unmodifiable(
      candidates.take(4).map(_AggregationSource.fromNote),
    );
    _notify();
  }

  void toggleNote(String localId) {
    if (_phase != FeedAggregationPhase.selecting || busy) return;
    final selected = _sources
        .where((source) => source.localId != localId)
        .toList();
    if (selected.length == _sources.length) {
      if (selected.length >= 4) return;
      final candidates = eligibleNotes.where((note) => note.id == localId);
      if (candidates.isEmpty) return;
      selected.add(_AggregationSource.fromNote(candidates.first));
    }
    _sources = List.unmodifiable(selected);
    _notify();
  }

  void cancelSelection({Object? owner}) {
    if (_disposed ||
        (owner != null && !ownsSelection(owner)) ||
        (_phase != FeedAggregationPhase.selecting &&
            _phase != FeedAggregationPhase.preparing)) {
      return;
    }
    _generation++;
    _selectionOwner = null;
    _busy = false;
    _sources = const [];
    _setPhase(FeedAggregationPhase.idle);
  }

  Future<V3FeedItem?> confirm() async {
    if (!canConfirm) {
      if (_phase == FeedAggregationPhase.selecting && !busy) {
        _setPhase(
          FeedAggregationPhase.failed,
          _ready ? 'AGGREGATION_SELECTION_CHANGED' : 'WORKSPACE_NOT_READY',
        );
      }
      return null;
    }
    _createdAt = _now().toUtc();
    _idempotencyKey =
        'topic-collision-${_createdAt!.microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    await _submit();
    return generatedNote;
  }

  Future<void> _submit() async {
    if (_disposed || busy || !_checkWorkspace()) return;
    if (_createdAt == null || _idempotencyKey == null || _sources.length != 4) {
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_CHECKPOINT_INVALID');
      return;
    }
    if (_now().toUtc().difference(_createdAt!) >= const Duration(hours: 24)) {
      _setPhase(
        FeedAggregationPhase.blocked,
        'AGGREGATION_IDEMPOTENCY_EXPIRED',
      );
      await _persist();
      return;
    }
    _busy = true;
    final generation = _generation;
    final workspace = _workspace!;
    _setPhase(FeedAggregationPhase.submitting);
    try {
      if (!await _persist()) return;
      if (!_owns(generation, workspace)) return;
      final result = await _remote
          .submit(
            workspace,
            noteIds: List.unmodifiable(_sources.map((source) => source.noteId)),
            idempotencyKey: _idempotencyKey!,
          )
          .timeout(requestTimeout);
      if (!_owns(generation, workspace)) return;
      _traceId = result.traceId;
      if (result.ok && result.data != null) {
        await _acceptRun(result.data!);
      } else {
        final code = result.error?.code ?? 'AGGREGATION_SUBMISSION_UNCERTAIN';
        if (code == 'IDEMPOTENCY_KEY_CONFLICT') {
          _setPhase(FeedAggregationPhase.blocked, code);
        } else if (_definiteRejection(result)) {
          _setPhase(FeedAggregationPhase.failed, code);
        } else {
          _setPhase(FeedAggregationPhase.submissionUncertain, code);
        }
        await _persist();
      }
    } catch (_) {
      if (_owns(generation, workspace)) {
        _setPhase(
          _run == null
              ? FeedAggregationPhase.submissionUncertain
              : FeedAggregationPhase.blocked,
          _run == null
              ? 'AGGREGATION_SUBMISSION_UNCERTAIN'
              : 'AGGREGATION_READ_INTERRUPTED',
        );
        await _persist();
      }
    } finally {
      _busy = false;
      _notify();
      _startPolling();
    }
  }

  Future<void> retry() async {
    if (_disposed || !canResume) return;
    _poller?.stop();
    _stopForegroundWait();
    _busy = true;
    _notify();
    try {
      if (_unreadable) {
        _initializedWorkspace = null;
        _restore();
        return;
      }
      if (!_checkWorkspace()) return;
      if (_storageBlocked && !await _persist()) return;
      if (_disposed || !_checkWorkspace()) return;
      _readFailures = 0;
      _outputReads = 0;
      if (_run == null) {
        if (_idempotencyKey == null) {
          _setPhase(FeedAggregationPhase.idle);
          return;
        }
        _busy = false;
        await _submit();
      } else if (_run!.isTerminal) {
        await _acceptRun(_run!);
      } else {
        _setPhase(FeedAggregationPhase.restoring);
        await _persist();
      }
    } finally {
      _busy = false;
      _notify();
      _startPolling();
    }
  }

  Future<void> _acceptRun(
    TopicCollisionRun incoming, {
    AppTaskCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (incoming.workspaceId != _workspace ||
        incoming.selectedNoteCount != 4 ||
        !topicCollisionStatuses.contains(incoming.status) ||
        (_run != null &&
            _run!.topicCollisionRunId != incoming.topicCollisionRunId) ||
        (incoming.isSuccessful && incoming.outputNoteId == null)) {
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_RUN_MISMATCH');
      await _persist();
      return;
    }
    _run = incoming;
    final phase = switch (incoming.status) {
      'queued' => FeedAggregationPhase.queued,
      'leased' => FeedAggregationPhase.leased,
      'admitting' => FeedAggregationPhase.admitting,
      'running' => FeedAggregationPhase.running,
      'retry_wait' => FeedAggregationPhase.retryWaiting,
      'succeeded' => FeedAggregationPhase.syncingResult,
      _ => FeedAggregationPhase.failed,
    };
    _setPhase(
      phase,
      phase == FeedAggregationPhase.failed
          ? incoming.failureCode ?? 'TOPIC_COLLISION_FAILED'
          : null,
    );
    if (!await _persist()) return;
    cancellationToken?.throwIfCancelled();
    if (incoming.isSuccessful) await _loadOutput(cancellationToken);
  }

  Future<void> _loadOutput(AppTaskCancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    if (_disposed || !_checkWorkspace()) return;
    final generation = _generation;
    final workspace = _workspace!;
    final run = _run!;
    _outputReads++;
    var synchronized = false;
    try {
      synchronized = await _library
          .reconcileRemoteNotesForChatReference()
          .timeout(requestTimeout);
      if (synchronized) {
        synchronized = await _library.flushPersistenceResult().timeout(
          requestTimeout,
        );
      }
    } catch (_) {
      synchronized = false;
    }
    cancellationToken?.throwIfCancelled();
    if (!_owns(generation, workspace)) return;
    final outputs = _library.notes.where(
      (note) => _isReadableOutput(note, run.outputNoteId),
    );
    if (!synchronized || outputs.isEmpty) {
      if (_outputReads >= maxOutputReads) {
        _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_OUTPUT_PENDING');
        await _persist();
      }
      return;
    }
    final note = outputs.first;
    _phase = _dismissed
        ? FeedAggregationPhase.idle
        : FeedAggregationPhase.succeeded;
    _errorCode = null;
    if (!await _persist(publishedOutputNoteId: run.outputNoteId)) return;
    cancellationToken?.throwIfCancelled();
    if (!_owns(generation, workspace)) return;
    _publishedOutputNoteId = run.outputNoteId;
    _generatedNoteId = note.id;
    _stopForegroundWait();
    _log();
    try {
      _profileHub.recordActivity(
        V3ProfileActivity(
          id: 'topic-collision-${run.topicCollisionRunId}',
          occurredAt: _now(),
          type: V3ProfileActivityType.summary,
          title: note.title,
          feedItemId: note.id,
          route: '/v3/feed/items/${Uri.encodeComponent(note.id)}?stage=raw',
        ),
      );
    } catch (_) {
      _log('Aggregation activity projection unavailable');
    }
    _notify();
  }

  void attachPollingRuntime({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
  }) {
    _poller?.dispose();
    _poller = OrchestratedPoller(
      orchestrator: orchestrator,
      activityMetrics: activityMetrics,
      interval: pollInterval,
      spec: TaskSpec(
        key: 'feed-aggregation:production-run-poll',
        owner: 'feed-aggregation-poll',
        resources: const {TaskResource.network},
        priority: TaskPriority.foregroundDeferred,
        deadline: requestTimeout * 3,
        retryable: true,
        replaceExisting: true,
        foregroundOnly: true,
      ),
      poll: (token) async {
        await _poll(token);
        return !_paused && _readsPending;
      },
    );
    _log('Aggregation polling runtime attached');
    _startPolling();
  }

  void pause() {
    _paused = true;
    _stopForegroundWait();
    _poller?.stop();
  }

  void resume() {
    if (_disposed) return;
    _paused = false;
    _restore();
    if (!_checkWorkspace()) return;
    if (_phase == FeedAggregationPhase.blocked &&
        _errorCode == 'WORKSPACE_NOT_READY' &&
        _run != null) {
      unawaited(retry());
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    if (_disposed ||
        _paused ||
        !_readsPending ||
        _run == null ||
        _poller == null ||
        _storageBlocked) {
      return;
    }
    if (!_checkWorkspace()) return;
    final generation = _generation;
    _foregroundWaitTimer ??= Timer(maxForegroundWait, () {
      _foregroundWaitTimer = null;
      if (_disposed ||
          _paused ||
          generation != _generation ||
          !_readsPending ||
          !_checkWorkspace()) {
        return;
      }
      _poller?.stop();
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_WAIT_PAUSED');
      unawaited(_persist());
    });
    _poller?.start();
  }

  void _stopForegroundWait() {
    _foregroundWaitTimer?.cancel();
    _foregroundWaitTimer = null;
  }

  Future<void> _poll(AppTaskCancellationToken token) async {
    if (_disposed || busy || !_readsPending || !_checkWorkspace()) return;
    _polling = true;
    final generation = _generation;
    final workspace = _workspace!;
    try {
      if (_run!.isSuccessful) {
        await _loadOutput(token);
        return;
      }
      final result = await _remote
          .get(workspace, _run!.topicCollisionRunId)
          .timeout(requestTimeout);
      token.throwIfCancelled();
      if (!_owns(generation, workspace)) return;
      _traceId = result.traceId;
      if (!result.ok || result.data == null) {
        final code = result.error?.code ?? 'AGGREGATION_READ_INTERRUPTED';
        if (result.status == 401 ||
            result.status == 403 ||
            result.status == 404 ||
            code == 'API_RESPONSE_INVALID' ||
            code.contains('IDEMPOTENCY')) {
          _setPhase(FeedAggregationPhase.blocked, code);
          await _persist();
          return;
        }
        throw StateError(code);
      }
      _readFailures = 0;
      await _acceptRun(result.data!, cancellationToken: token);
      if (_owns(generation, workspace) &&
          _run?.topicCollisionRunId == result.data!.topicCollisionRunId &&
          _lastObservedRunId != _run!.topicCollisionRunId) {
        _lastObservedRunId = _run!.topicCollisionRunId;
        _log('Aggregation task query received');
      }
    } catch (_) {
      token.throwIfCancelled();
      if (!_owns(generation, workspace)) return;
      _readFailures++;
      if (_readFailures >= maxReadFailures) {
        _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_READ_INTERRUPTED');
        await _persist();
        return;
      }
      _errorCode = 'AGGREGATION_READ_RETRYING';
      _notify();
      rethrow;
    } finally {
      _polling = false;
      _notify();
    }
  }

  void dismissCompletion() {
    if (_phase != FeedAggregationPhase.succeeded || busy) return;
    _dismissed = true;
    _setPhase(FeedAggregationPhase.idle);
    _persist();
  }

  void _handleLibraryChanged() {
    if (_disposed) return;
    if (_phase == FeedAggregationPhase.selecting) {
      if (_selectedSourcesAreEligible) {
        _notify();
      } else {
        _setPhase(FeedAggregationPhase.failed, 'AGGREGATION_SELECTION_CHANGED');
      }
      return;
    }
    if (_phase != FeedAggregationPhase.succeeded ||
        _generatedNoteId == null ||
        generatedNote != null) {
      if (_settledTasks.isNotEmpty || _generatedNoteId != null) _notify();
      return;
    }
    _generatedNoteId = null;
    _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_OUTPUT_UNAVAILABLE');
    unawaited(_persist());
  }

  bool _checkWorkspace() {
    if (!_ready) {
      if (hasUnresolvedTask) {
        _setPhase(FeedAggregationPhase.blocked, 'WORKSPACE_NOT_READY');
      }
      return false;
    }
    if (_workspace != null && _workspace != _workspaceId()!.trim()) {
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_WORKSPACE_CHANGED');
      return false;
    }
    return true;
  }

  bool _owns(int generation, String workspace) {
    if (_disposed || generation != _generation) return false;
    if (workspace != _workspaceId()?.trim()) {
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_WORKSPACE_CHANGED');
      return false;
    }
    return _checkWorkspace();
  }

  void _restore() {
    if (!_ready || _initializedWorkspace != null || _disposed) return;
    final workspace = _workspaceId()!.trim();
    _initializedWorkspace = workspace;
    final preferences = _preferences;
    if (preferences == null) return;
    try {
      final raw =
          preferences.readValue(_key(workspace)) ??
          preferences.readValue(_legacyKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || !_validId(decoded['workspaceId'])) {
        throw const FormatException();
      }
      if (decoded['workspaceId'] != workspace) return;
      final history = decoded['settledTasks'];
      if (history != null && history is! List) throw const FormatException();
      for (final value in (history as List? ?? const [])) {
        final record = Map<String, Object?>.from(value as Map);
        if (!_validId(record['reference']) ||
            (record['errorCode'] != null && record['errorCode'] is! String) ||
            !const ['failed', 'succeeded'].contains(record['phase'])) {
          throw const FormatException();
        }
        DateTime.parse(record['createdAt']! as String);
        final sources = (record['sources']! as List)
            .map(_AggregationSource.fromJson)
            .toList();
        final legacyRunOnly = sources.isEmpty && record['run'] != null;
        if ((!legacyRunOnly && sources.length != 4) ||
            sources.map((source) => source.noteId).toSet().length !=
                sources.length ||
            sources.map((source) => source.localId).toSet().length !=
                sources.length) {
          throw const FormatException();
        }
        if (record['run'] != null) {
          final run = TopicCollisionRun.fromJson(
            Map<String, Object?>.from(record['run']! as Map),
          );
          if (run.workspaceId != workspace ||
              !run.isTerminal ||
              (record['phase'] == 'succeeded' && !run.isSuccessful)) {
            throw const FormatException();
          }
        } else if (record['phase'] == 'succeeded') {
          throw const FormatException();
        }
        _settledTasks[record['reference']! as String] = record;
      }
      _workspace = workspace;
      _unreadable = false;
      _dismissed = decoded['dismissed'] == true;
      if (decoded['schema'] == 2) {
        if (decoded['userScope'] != _userScope) throw const FormatException();
        _idempotencyKey = decoded['idempotencyKey'] as String?;
        if (_idempotencyKey != null && !_validId(_idempotencyKey)) {
          throw const FormatException();
        }
        _createdAt = decoded['createdAt'] == null
            ? null
            : DateTime.parse(decoded['createdAt'] as String).toUtc();
        _sources = List.unmodifiable(
          (decoded['selectedSources'] as List).map(
            (value) => _AggregationSource.fromJson(value),
          ),
        );
        if (_sources.map((source) => source.noteId).toSet().length !=
            _sources.length) {
          throw const FormatException();
        }
        if (_sources.map((source) => source.localId).toSet().length !=
            _sources.length) {
          throw const FormatException();
        }
        _run = decoded['run'] == null
            ? null
            : TopicCollisionRun.fromJson(
                Map<String, Object?>.from(decoded['run'] as Map),
              );
        _errorCode = decoded['errorCode'] as String?;
        final savedPhase = FeedAggregationPhase.values.byName(
          decoded['phase'] as String,
        );
        _publishedOutputNoteId = decoded['publishedOutputNoteId'] as String?;
        if (_publishedOutputNoteId == null &&
            _run?.isSuccessful == true &&
            (savedPhase == FeedAggregationPhase.succeeded ||
                savedPhase == FeedAggregationPhase.idle ||
                _errorCode == 'AGGREGATION_OUTPUT_UNAVAILABLE')) {
          _publishedOutputNoteId = _run!.outputNoteId;
        }
        if (_publishedOutputNoteId != null &&
            (!_validId(_publishedOutputNoteId) ||
                _run?.isSuccessful != true ||
                _publishedOutputNoteId != _run!.outputNoteId)) {
          throw const FormatException();
        }
        if (_run == null &&
            _idempotencyKey != null &&
            (_sources.length != 4 || _createdAt == null)) {
          throw const FormatException();
        }
        _phase = _run == null
            ? (_idempotencyKey == null
                  ? FeedAggregationPhase.idle
                  : savedPhase == FeedAggregationPhase.failed
                  ? FeedAggregationPhase.failed
                  : FeedAggregationPhase.submissionUncertain)
            : _run!.isSuccessful
            ? FeedAggregationPhase.syncingResult
            : _run!.isTerminal
            ? FeedAggregationPhase.failed
            : FeedAggregationPhase.restoring;
        if (savedPhase == FeedAggregationPhase.blocked) {
          _phase = FeedAggregationPhase.blocked;
        }
      } else {
        final runId = decoded['topicCollisionRunId'];
        if (!_validId(runId)) throw const FormatException();
        _createdAt = DateTime.parse(decoded['createdAt'] as String).toUtc();
        _run = TopicCollisionRun(
          topicCollisionRunId: runId as String,
          workspaceId: workspace,
          stage: 'restoring',
          status: 'queued',
          selectedNoteCount: 4,
        );
        _phase = FeedAggregationPhase.restoring;
      }
      if (_run != null && _run!.workspaceId != workspace) {
        throw const FormatException();
      }
      _log();
      _notify();
      _startPolling();
    } catch (_) {
      _unreadable = true;
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_CHECKPOINT_INVALID');
    }
  }

  Future<bool> _persist({String? publishedOutputNoteId}) async {
    final generation = _generation;
    if (_disposed || _workspace == null || _unreadable) return false;
    try {
      final preferences = _preferences;
      if (preferences == null) {
        throw StateError('AGGREGATION_STORAGE_UNAVAILABLE');
      }
      final value = jsonEncode({
        'schema': 2,
        'settledTasks': _settledTasks.values.toList(),
        'userScope': _userScope,
        'workspaceId': _workspace,
        'phase': _phase.name,
        'idempotencyKey': _idempotencyKey,
        'createdAt': _createdAt?.toIso8601String(),
        'selectedSources': _sources.map((source) => source.toJson()).toList(),
        'run': _run?.toJson(),
        'publishedOutputNoteId':
            publishedOutputNoteId ?? _publishedOutputNoteId,
        'errorCode': _errorCode,
        'dismissed': _dismissed,
      });
      if (value != _lastPersisted || _storageBlocked) {
        await preferences.upsertValueDeferred(
          preferenceKey: _key(_workspace!),
          updatedAt: _now().toUtc().toIso8601String(),
          value: value,
        );
      }
      if (_disposed || generation != _generation) return false;
      _lastPersisted = value;
      _storageBlocked = false;
      return true;
    } catch (_) {
      if (_disposed || generation != _generation) return false;
      _storageBlocked = true;
      _setPhase(FeedAggregationPhase.blocked, 'AGGREGATION_STORAGE_FAILED');
      return false;
    }
  }

  String _key(String workspace) =>
      'topic-collision-${sha256.convert(utf8.encode('$_userScope|$workspace')).toString().substring(0, 24)}';
  String get _legacyKey =>
      'topic-collision-${sha256.convert(utf8.encode(_userScope)).toString().substring(0, 24)}';

  void _setPhase(FeedAggregationPhase phase, [String? errorCode]) {
    if (_disposed) return;
    if (_phase == phase && _errorCode == errorCode) return;
    _phase = phase;
    _errorCode = errorCode;
    if (!_readsPending) _stopForegroundWait();
    _log();
    _notify();
  }

  void _log([String summary = 'Aggregation task state changed']) {
    try {
      _logger?.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.feedAi,
          severity: _errorCode == null
              ? DiagnosticSeverity.info
              : DiagnosticSeverity.warning,
          safeSummary: summary,
          correlationId: taskId,
          flushImmediately: true,
          metadata: {
            'stage': _phase.name,
            'scope_hash': _workspace == null ? null : _key(_workspace!),
            'user_scope': _userScope,
            'topic_collision_run_id': _run?.topicCollisionRunId,
            'error_code': _errorCode,
            'trace_id': _traceId,
            'backend_stage': _run?.stage,
            'backend_status': _run?.status,
            'polling_attached': _poller != null,
            'polling_paused': _paused,
            'failure_stage': _run?.failureStage,
            'attempt': _run?.attempt,
            'read_failures': _readFailures,
          },
        ),
      );
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _stopForegroundWait();
    _library.removeListener(_handleLibraryChanged);
    _poller?.dispose();
    super.dispose();
  }
}

final class FeedAggregationTaskNotice {
  const FeedAggregationTaskNotice({
    required this.reference,
    required this.runId,
    required this.phase,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.note,
    required this.sources,
    required this.isCurrent,
    this.errorCode,
  });
  final String reference;
  final String? runId;
  final FeedAggregationPhase phase;
  final String title;
  final String message;
  final DateTime createdAt;
  final V3FeedItem? note;
  final List<V3FeedItem> sources;
  final bool isCurrent;
  final String? errorCode;
  int get sourceCount => sources.isEmpty && runId != null ? 4 : sources.length;
  bool matches(String? value) =>
      value != null &&
      value.isNotEmpty &&
      (value == reference || value == runId);
}

final class _AggregationSource {
  const _AggregationSource(this.localId, this.noteId, this.title);
  factory _AggregationSource.fromNote(V3FeedItem note) =>
      _AggregationSource(note.id, note.remoteNoteId!, note.title);
  factory _AggregationSource.fromJson(Object? value) {
    if (value is! Map ||
        !_validId(value['localId']) ||
        !_validId(value['noteId']) ||
        value['title'] is! String) {
      throw const FormatException('Invalid aggregation selection');
    }
    return _AggregationSource(
      value['localId'] as String,
      value['noteId'] as String,
      value['title'] as String,
    );
  }
  final String localId;
  final String noteId;
  final String title;
  Map<String, String> toJson() => {
    'localId': localId,
    'noteId': noteId,
    'title': title,
  };
}

bool _validId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(value);

bool _definiteRejection(ApiResult<TopicCollisionRun> result) {
  final status = result.status;
  final code = result.error?.code;
  return status != null &&
      status >= 400 &&
      status < 500 &&
      status != 408 &&
      code != 'API_RESPONSE_INVALID' &&
      code != null &&
      const {
        'INVALID_ARGUMENT',
        'NOTE_TOPIC_SOURCE_INSUFFICIENT',
        'NOTE_FOLDER_NOT_FOUND',
        'IDEMPOTENCY_KEY_REQUIRED',
        'QUOTA_INSUFFICIENT',
        'SERVICE_BUSY',
        'AGENT_PROFILE_NOT_SELECTABLE',
        'AGENT_RELEASE_UNAVAILABLE',
        'WORKSPACE_VERSION_CONFLICT',
        'NOTE_TOPIC_COLLISION_UNAVAILABLE',
        'UNAUTHORIZED',
        'FORBIDDEN',
        'WORKSPACE_NOT_READY',
      }.contains(code);
}

String _errorMessage(String code) => switch (code) {
  'INVALID_ARGUMENT' => '提交的来源不符合要求。请重新选择四篇不同且已同步的有效笔记。',
  'AGGREGATION_SELECTION_CHANGED' => '所选来源已发生变化，尚未提交聚合。请重新核对四篇不同且已同步的有效笔记。',
  'AGGREGATION_NOT_ENOUGH_DEPOSITED_ASSETS' ||
  'NOTE_TOPIC_SOURCE_INSUFFICIENT' => '至少需要四篇已同步、正文非空且不是历史聚合结果的笔记。请先同步或补充笔记。',
  'AGGREGATION_SOURCE_SYNC_FAILED' => '未能同步云端来源，尚未提交聚合。请恢复连接后重新选择。',
  'AGGREGATION_SOURCE_SYNC_PENDING' => '已核对部分旧版笔记，仍有来源信息需要同步。请继续核对来源，尚未提交聚合。',
  'AGGREGATION_STORAGE_FAILED' => '本机无法保存聚合进度，已暂停后续请求。请释放存储空间后重试保存，原任务信息仍被保留。',
  'AGGREGATION_CHECKPOINT_INVALID' =>
    '本机聚合记录无法读取，已停止新建任务以避免重复生成。请重启后重试或联系支持核查。',
  'AGGREGATION_IDEMPOTENCY_EXPIRED' =>
    '受理结果未确认且已超过24小时安全重试窗口。请联系支持核查原任务，不能直接重新提交。',
  'IDEMPOTENCY_KEY_CONFLICT' => '原请求与云端幂等记录不一致，已阻止重复生成。请联系支持核查。',
  'AGGREGATION_OUTPUT_PENDING' => '云端已成功生成，但结果笔记尚未同步到本机。请继续同步结果，不会重新生成。',
  'AGGREGATION_OUTPUT_UNAVAILABLE' =>
    '聚合已完成，但结果笔记当前不可读取。请重新同步原结果；若笔记已删除，请返回查看其他资产。不会重新生成。',
  'NOTE_TOPIC_COLLISION_OUTPUT_INVALID' =>
    '云端生成的聚合结果未通过校验，本次未产出可用笔记。可稍后重新发起；若重复出现，请提供任务编号联系支持。',
  'API_RESPONSE_INVALID' ||
  'AGGREGATION_RUN_MISMATCH' => '云端响应与当前任务协议不一致。已保留原任务，请更新应用或稍后继续确认，不能另建任务。',
  'AGGREGATION_WORKSPACE_CHANGED' => '当前工作区已变化。请回到发起聚合的账号和工作区后继续查看。',
  'WORKSPACE_NOT_READY' ||
  'UNAUTHORIZED' ||
  'AUTH_REQUIRED' ||
  'TOKEN_EXPIRED' => '登录或工作区尚未就绪。请完成登录并回到原工作区后继续。',
  'FORBIDDEN' => '当前账号无权读取任务。请确认发起聚合的账号后继续。',
  'NOTE_TOPIC_COLLISION_NOT_FOUND' ||
  'NOT_FOUND' => '暂时无法找到原任务，记录已保留。请核对账号或联系支持，不会自动重新生成。',
  'QUOTA_INSUFFICIENT' => '当前额度不足，本次未能继续。请补充额度后重新发起。',
  'AGGREGATION_READ_RETRYING' => '读取进度暂时中断，正在重试查询。云端任务不会因此取消或重新生成。',
  'AGGREGATION_READ_INTERRUPTED' ||
  'AGGREGATION_WAIT_PAUSED' => '本轮进度查询已暂停，原任务仍被保留。点击继续查询，不会重新生成。',
  'AGGREGATION_SUBMISSION_UNCERTAIN' => '尚未确认云端是否受理。请继续确认同一次请求，不会重复创建任务。',
  _ => '聚合状态需要确认（$code）。请按当前操作提示处理，原任务信息已保留。',
};
