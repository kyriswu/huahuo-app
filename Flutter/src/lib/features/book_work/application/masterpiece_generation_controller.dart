import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/tasking/task_orchestrator.dart';
import '../domain/masterpiece_generation.dart';
import '../domain/masterpiece_state.dart';

export '../domain/masterpiece_generation.dart';

final class MasterpieceGenerationController extends ChangeNotifier {
  factory MasterpieceGenerationController({
    required MasterpieceGenerationRemote remote,
    required MasterpieceGenerationStore store,
    required String identity,
    TaskOrchestrator? orchestrator,
  }) => MasterpieceGenerationController._(
    remote,
    store,
    sha256.convert(utf8.encode(identity)).toString(),
    orchestrator,
  );

  MasterpieceGenerationController._(
    this._remote,
    this._store,
    this._identity,
    this._orchestrator,
  ) {
    try {
      _record = _store.read() ?? const MasterpieceGenerationRecord();
    } catch (_) {
      _unreadable = true;
      _errorCode = 'MASTERPIECE_GENERATION_STORAGE_UNREADABLE';
    }
  }

  final MasterpieceGenerationRemote _remote;
  final MasterpieceGenerationStore _store;
  final String _identity;
  final TaskOrchestrator? _orchestrator;
  MasterpieceGenerationRecord _record = const MasterpieceGenerationRecord();
  MasterpieceGenerationRecord? _pendingRecord;
  MasterpieceSnapshot? _book;
  MasterpieceSnapshot? _confirmedSnapshot;
  Future<void>? _flight;
  String? _errorCode;
  bool _unreadable = false;
  bool _eligibilityVerified = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _documentIdle = false;
  bool _polling = false;
  bool _pollPaused = false;
  int _pollGeneration = 0;

  MasterpieceGenerationRecord get record => _record;
  MasterpieceGenerationIntent? get intent => _record.intent;
  MasterpieceSnapshot? get confirmedSnapshot => _confirmedSnapshot;
  String? get errorCode => _errorCode;
  bool get busy => _flight != null;
  bool get eligibilityVerified => _eligibilityVerified;
  bool get unlocked =>
      _eligibilityVerified && _record.noteCount >= masterpieceUnlockCount;
  bool get allowsEditing =>
      !_disposed &&
      !_unreadable &&
      _pendingRecord == null &&
      unlocked &&
      _record.settled &&
      intent == null &&
      !busy;
  bool get showPanel => !allowsEditing;
  bool get canCancel =>
      !busy &&
      intent != null &&
      const {
        MasterpieceGenerationStage.submitting,
        MasterpieceGenerationStage.uncertain,
        MasterpieceGenerationStage.running,
        MasterpieceGenerationStage.awaitingInput,
      }.contains(intent!.stage);
  bool get canDismiss =>
      !busy &&
      !_unreadable &&
      _pendingRecord == null &&
      unlocked &&
      (intent?.canDiscard == true ||
          (intent == null && _record.automaticAttempted && !_record.settled));
  bool get canRestart =>
      !busy &&
      _documentIdle &&
      unlocked &&
      !_unreadable &&
      _pendingRecord == null &&
      (intent == null ||
          const {
            MasterpieceGenerationStage.failed,
            MasterpieceGenerationStage.cancelled,
          }.contains(intent!.stage));
  bool get _needsPolling =>
      intent?.stage == MasterpieceGenerationStage.running ||
      intent?.stage == MasterpieceGenerationStage.accepted;
  String get _taskKey => 'masterpiece:$_identity';

  String get statusMessage {
    if (_unreadable) return '生成记录无法读取，已停止自动请求以保护未完成的任务。请重启后重试。';
    if (_pendingRecord != null) return '生成进度保存失败，已暂停网络操作。请释放本机空间后重试。';
    if (!unlocked) {
      if (busy) return '正在核对云端有效笔记…';
      if (!_eligibilityVerified) return '尚未完成云端笔记核验，代表作暂未解锁。请重新核对云端笔记。';
      return '已沉淀 ${_record.noteCount} / $masterpieceUnlockCount 篇，未满 100 篇暂不解锁。已有正文与草稿会保留。';
    }
    if (_errorCode == 'MASTERPIECE_AGENT_UNAVAILABLE') {
      return '代表作已解锁，但云端暂未开放代表作写作能力。已保留资格，请稍后重试。';
    }
    if (_errorCode?.contains('IDEMPOTENCY') == true) {
      return '同一代表作请求已在云端登记，但请求内容不一致。已停止新建任务，请在原设备确认任务结果后重试。';
    }
    if (intent == null) {
      if (_record.settled) return '代表作已解锁，云端正文可以继续编辑。';
      if (!_documentIdle) return '已解锁。请先复制或放弃未提交的章节草稿，再开始自动生成。';
      return busy ? '已解锁，正在准备固定版本的写作资料…' : '代表作已解锁，生成准备尚未完成，请重试。';
    }
    if (_pollPaused && _needsPolling) return '任务仍在云端处理，本轮等待已暂停。可继续查询，不会重新生成。';
    return switch (intent!.stage) {
      MasterpieceGenerationStage.submitting => '正在请求云端生成，请勿重复提交。',
      MasterpieceGenerationStage.uncertain => '生成请求的受理结果尚未确认，请重试同一次请求。',
      MasterpieceGenerationStage.running =>
        intent!.cancelRequested
            ? '正在等待云端确认取消，确认前不会启动其他任务。'
            : '代表作正在云端生成，离开页面不会取消任务。',
      MasterpieceGenerationStage.awaitingInput =>
        intent!.clarification ?? '云端需要补充信息。可先取消本次任务，再重新发起。',
      MasterpieceGenerationStage.generated =>
        _errorCode == 'MASTERPIECE_BOOK_CHANGED'
            ? '生成期间云端代表作已变化。生成稿已保留，未覆盖现有正文。'
            : '正文已生成，等待正式收录到云端。',
      MasterpieceGenerationStage.publishing => '正在收录生成正文；结果未知时只重试同一次收录。',
      MasterpieceGenerationStage.accepted => '云端已接受收录，正在回读确认，暂不能编辑。',
      MasterpieceGenerationStage.failed => '本次生成未完成，不会自动重复请求。可确认后重新生成。',
      MasterpieceGenerationStage.cancelled => '云端已确认取消。本次不会收录，可重新生成或结束本次任务。',
    };
  }

  void invalidateEligibility() {
    if (_disposed || !_eligibilityVerified) return;
    _eligibilityVerified = false;
    _notify();
  }

  Future<void> reconcile({
    required MasterpieceSnapshot? snapshot,
    required bool documentIdle,
  }) {
    _book = snapshot;
    _documentIdle = documentIdle;
    return _action(() async {
      final eligibility = await _refreshEligibility();
      if (eligibility == null || !_active || snapshot == null) return;
      if (intent != null) {
        await _advance();
        return;
      }
      if (!unlocked) return;
      if (snapshot.chapters.isNotEmpty) {
        if (!_record.settled) {
          await _save(
            _record.copyWith(automaticAttempted: true, settled: true),
          );
        }
        return;
      }
      if (_record.settled || _record.automaticAttempted) return;
      if (_active && unlocked && _documentIdle) {
        await _start(snapshot, eligibility: eligibility);
      }
    });
  }

  void setDocumentIdle(bool idle) {
    _documentIdle = idle;
  }

  Future<void> requestGeneration() => _action(() async {
    if (!_documentIdle ||
        !unlocked ||
        (intent != null &&
            !const {
              MasterpieceGenerationStage.failed,
              MasterpieceGenerationStage.cancelled,
            }.contains(intent!.stage))) {
      return;
    }
    final eligibility = await _refreshEligibility();
    if (eligibility == null || !_active || !unlocked) return;
    final snapshot = await _wait(_remote.book());
    if (!_active) return;
    _book = snapshot;
    await _save(
      _record.copyWith(
        attempt: _record.automaticAttempted
            ? _record.attempt + 1
            : _record.attempt,
        clearIntent: true,
        settled: false,
        published: false,
      ),
    );
    await _start(snapshot, eligibility: eligibility);
  });

  Future<void> retry() => _action(() async {
    _pollPaused = false;
    if (intent != null) await _advance();
  });

  Future<void> cancel() => _action(() async {
    final current = intent;
    if (current == null ||
        !const {
          MasterpieceGenerationStage.submitting,
          MasterpieceGenerationStage.uncertain,
          MasterpieceGenerationStage.running,
          MasterpieceGenerationStage.awaitingInput,
        }.contains(current.stage)) {
      return;
    }
    await _save(
      _record.copyWith(intent: current.copyWith(cancelRequested: true)),
    );
    await _advance();
  });

  Future<void> dismiss() => _action(() async {
    if (!unlocked || (intent != null && !intent!.canDiscard)) return;
    await _save(
      _record.copyWith(
        clearIntent: true,
        settled: true,
        automaticAttempted: true,
      ),
    );
  });

  Future<MasterpieceEligibility?> _refreshEligibility() async {
    _eligibilityVerified = false;
    try {
      final eligibility = await _wait(_remote.eligibility());
      if (!_active) return null;
      await _save(
        _record.copyWith(
          noteCount: eligibility.count,
          unlocked:
              _record.unlocked || eligibility.count >= masterpieceUnlockCount,
        ),
      );
      if (!_active) return null;
      _eligibilityVerified = true;
      return eligibility;
    } catch (error) {
      if (!_disposed) {
        _errorCode = error is MasterpieceRemoteException
            ? error.code
            : 'MASTERPIECE_GENERATION_NETWORK_FAILED';
      }
      return null;
    }
  }

  Future<void> _start(
    MasterpieceSnapshot snapshot, {
    required MasterpieceEligibility eligibility,
  }) async {
    if (!_active || !unlocked || eligibility.count < masterpieceUnlockCount) {
      return;
    }
    await _save(
      _record.copyWith(
        automaticAttempted: true,
        settled: false,
        published: false,
      ),
    );
    if (!_active) return;
    final sources = eligibility;
    final preparation = await _wait(_remote.prepare(sources));
    if (!_active) return;
    final identity = sha256
        .convert(
          utf8.encode('$_identity:${snapshot.book.bookId}:${_record.attempt}'),
        )
        .toString();
    final initial = snapshot.chapters.isEmpty;
    final next = MasterpieceGenerationIntent(
      bookId: snapshot.book.bookId,
      baseBookRevisionId: snapshot.book.currentBookRevisionId,
      profileId: preparation.profileId,
      instruction:
          '请根据附带的 ${preparation.sources.length} 篇固定版本笔记，'
          '为用户${initial ? "创作第一份代表作" : "创作代表作的新篇章"}。'
          '用中文 Markdown 输出完整、连贯、有目录层次的正文，提炼真实经历、观点和方法，'
          '不要编造未在资料中出现的个人事实。只返回正文，不返回操作说明、确认问题或保存成功声明。'
          '本次只生成候选正文，不修改已有笔记或代表作；客户端随后通过正式章节接口收录。',
      sources: List.unmodifiable(preparation.sources),
      sectionKey: initial
          ? 'masterpiece-initial'
          : 'masterpiece-${identity.substring(0, 20)}',
      title: initial ? '代表作 · 初稿' : '代表作 · 新篇章',
      requestKey: 'masterpiece-run-$identity',
      initial: initial,
    );
    await _save(_record.copyWith(noteCount: sources.count, intent: next));
    if (_active) await _advance();
  }

  Future<void> _advance() async {
    if (!_active) return;
    final current = intent;
    if (current == null) return;
    if (_book != null && _book!.book.bookId != current.bookId) {
      throw const MasterpieceRemoteException('MASTERPIECE_BOOK_CHANGED');
    }
    switch (current.stage) {
      case MasterpieceGenerationStage.submitting:
      case MasterpieceGenerationStage.uncertain:
        final run = await _wait(_remote.create(current));
        if (_disposed) return;
        await _save(
          _record.copyWith(
            intent: current.copyWith(
              stage: MasterpieceGenerationStage.running,
              runId: run.agentRunId,
            ),
          ),
        );
        await _applyRun(run);
      case MasterpieceGenerationStage.running:
      case MasterpieceGenerationStage.awaitingInput:
        final shouldCancel = current.cancelRequested && !current.cancelSent;
        final run = await _wait(
          shouldCancel ? _remote.cancel(current) : _remote.run(current.runId!),
        );
        if (_disposed) return;
        if (shouldCancel) {
          await _save(
            _record.copyWith(intent: current.copyWith(cancelSent: true)),
          );
        }
        await _applyRun(run);
      case MasterpieceGenerationStage.generated:
        if (_documentIdle) await _publish();
      case MasterpieceGenerationStage.publishing:
        if (!_documentIdle) return;
        final visible = await _wait(_remote.readback(current));
        if (_disposed) return;
        if (visible != null) {
          await _finishPublication(visible);
          return;
        }
        if (!_active) return;
        await _submitPublication(current, replay: true);
        if (_disposed) return;
        await _save(
          _record.copyWith(
            intent: current.copyWith(
              stage: MasterpieceGenerationStage.accepted,
            ),
          ),
        );
        if (_active) await _readback();
      case MasterpieceGenerationStage.accepted:
        await _readback();
      case MasterpieceGenerationStage.failed:
      case MasterpieceGenerationStage.cancelled:
        break;
    }
  }

  Future<void> _applyRun(AgentRunSnapshot run) async {
    if (_disposed) return;
    final current = intent!;
    if (run.agentRunId != current.runId) {
      throw const MasterpieceRemoteException(
        'MASTERPIECE_RUN_IDENTITY_INVALID',
      );
    }
    if (run.status == 'succeeded') {
      final result = run.result;
      if (result == null ||
          result.completionMode != 'normal' ||
          result.finalAnswer.trim().isEmpty) {
        await _save(
          _record.copyWith(
            intent: current.copyWith(stage: MasterpieceGenerationStage.failed),
          ),
        );
        _errorCode = 'MASTERPIECE_GENERATION_OUTPUT_UNUSABLE';
        return;
      }
      await _save(
        _record.copyWith(
          intent: current.copyWith(
            stage: MasterpieceGenerationStage.generated,
            markdown: result.finalAnswer,
          ),
        ),
      );
      if (_active && _documentIdle && !current.cancelRequested) {
        await _publish();
      }
    } else if (const {
      'failed',
      'timeout',
      'cancelled',
      'orphaned',
    }.contains(run.status)) {
      await _save(
        _record.copyWith(
          intent: current.copyWith(
            stage: run.status == 'cancelled'
                ? MasterpieceGenerationStage.cancelled
                : MasterpieceGenerationStage.failed,
          ),
        ),
      );
      _errorCode = run.error?.code;
    } else {
      final awaitingInput = run.status == 'awaiting_confirmation';
      await _save(
        _record.copyWith(
          intent: current.copyWith(
            stage: awaitingInput
                ? MasterpieceGenerationStage.awaitingInput
                : MasterpieceGenerationStage.running,
            clarification: run.clarification?.userMessage,
          ),
        ),
      );
    }
  }

  Future<void> _publish() async {
    if (!_active || !_documentIdle) return;
    final current = intent!;
    if (current.cancelRequested) {
      _errorCode = 'MASTERPIECE_CANCELLED_OUTPUT_RETAINED';
      return;
    }
    final snapshot = await _wait(_remote.book());
    if (!_active) return;
    if (snapshot.book.bookId != current.bookId ||
        snapshot.book.currentBookRevisionId != current.baseBookRevisionId ||
        snapshot.chapter(current.sectionKey) != null) {
      _errorCode = 'MASTERPIECE_BOOK_CHANGED';
      return;
    }
    await _save(
      _record.copyWith(
        intent: current.copyWith(stage: MasterpieceGenerationStage.publishing),
      ),
    );
    if (!_active) return;
    await _submitPublication(intent!, replay: false);
    if (_disposed) return;
    await _save(
      _record.copyWith(
        intent: intent!.copyWith(stage: MasterpieceGenerationStage.accepted),
      ),
    );
    if (_active) await _readback();
  }

  Future<void> _readback() async {
    final snapshot = await _wait(_remote.readback(intent!));
    if (_disposed) return;
    if (snapshot == null) {
      _errorCode = 'MASTERPIECE_READBACK_PENDING';
      return;
    }
    await _finishPublication(snapshot);
  }

  Future<void> _submitPublication(
    MasterpieceGenerationIntent current, {
    required bool replay,
  }) async {
    try {
      await _wait(_remote.publish(current));
    } on MasterpieceRemoteException catch (error) {
      if (!_disposed && !replay && !error.ambiguous) {
        await _save(
          _record.copyWith(
            intent: current.copyWith(
              stage: MasterpieceGenerationStage.generated,
            ),
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _finishPublication(MasterpieceSnapshot snapshot) async {
    await _save(
      _record.copyWith(clearIntent: true, settled: true, published: true),
    );
    if (_disposed) return;
    _confirmedSnapshot = snapshot;
    _book = snapshot;
  }

  bool get _active => !_disposed && _foreground;

  Future<T> _wait<T>(Future<T> request) =>
      request.timeout(const Duration(seconds: 60));

  Future<void> _save(MasterpieceGenerationRecord next) async {
    if (_disposed) return;
    try {
      await _store.write(next);
      if (_disposed) return;
      _record = next;
      _pendingRecord = null;
      _notify();
    } catch (_) {
      if (!_disposed) _pendingRecord = next;
      throw const MasterpieceRemoteException(
        'MASTERPIECE_GENERATION_STORAGE_FAILED',
      );
    }
  }

  Future<void> _action(Future<void> Function() body) {
    if (_disposed || _unreadable || !_foreground) return Future.value();
    final existing = _flight;
    if (existing != null) return existing;
    final flight = Future<void>(() async {
      _errorCode = null;
      try {
        if (_pendingRecord != null) await _save(_pendingRecord!);
        if (_active) await body();
      } catch (error) {
        if (_disposed) return;
        final failure = error is MasterpieceRemoteException ? error : null;
        _errorCode = failure?.code ?? 'MASTERPIECE_GENERATION_NETWORK_FAILED';
        if (_pendingRecord != null) return;
        final current = intent;
        MasterpieceGenerationStage? next;
        if (current?.stage == MasterpieceGenerationStage.submitting ||
            current?.stage == MasterpieceGenerationStage.uncertain) {
          next =
              current!.stage == MasterpieceGenerationStage.uncertain ||
                  failure == null ||
                  failure.code.contains('IDEMPOTENCY') ||
                  failure.ambiguous
              ? MasterpieceGenerationStage.uncertain
              : MasterpieceGenerationStage.failed;
        }
        if (next != null) {
          try {
            await _save(
              _record.copyWith(intent: current!.copyWith(stage: next)),
            );
          } catch (_) {
            _errorCode = 'MASTERPIECE_GENERATION_STORAGE_FAILED';
          }
        }
      }
    });
    _flight = flight;
    _notify();
    return flight.whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
      _notify();
      _resumePolling();
    });
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _pollGeneration += 1;
      _polling = false;
      _orchestrator?.cancel(_taskKey, reason: 'masterpiece-backgrounded');
    } else {
      _pollPaused = false;
      _resumePolling();
    }
  }

  void _resumePolling() {
    final orchestrator = _orchestrator;
    if (!_active ||
        !_needsPolling ||
        _polling ||
        _pollPaused ||
        _pendingRecord != null ||
        orchestrator == null) {
      return;
    }
    _polling = true;
    final generation = ++_pollGeneration;
    unawaited(
      orchestrator
          .schedule<void>(
            TaskSpec(
              key: _taskKey,
              owner: 'masterpiece-generation',
              priority: TaskPriority.foregroundDeferred,
              resources: const {TaskResource.network},
              foregroundOnly: true,
              deadline: const Duration(minutes: 5),
            ),
            (token) async {
              for (
                var attempt = 0;
                attempt < 20 && _active && _needsPolling;
                attempt += 1
              ) {
                token.reportState(const AppTaskWaitingRemote());
                final seconds = min(20, 2 << min(attempt, 4));
                await token.delay(
                  Duration(
                    milliseconds: seconds * 1000 + Random().nextInt(500),
                  ),
                );
                if (!_active || !_needsPolling) return;
                await retry();
                token.throwIfCancelled();
                if (_pendingRecord != null) return;
              }
            },
          )
          .catchError((Object _) {})
          .whenComplete(() {
            if (_disposed || generation != _pollGeneration) return;
            _polling = false;
            _pollPaused = _needsPolling;
            _notify();
          }),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollGeneration += 1;
    _orchestrator?.cancel(_taskKey, reason: 'masterpiece-identity-disposed');
    super.dispose();
  }
}
