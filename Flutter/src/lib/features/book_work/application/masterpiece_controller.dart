import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/masterpiece_state.dart';
import 'masterpiece_generation_controller.dart';

export '../domain/masterpiece_state.dart';

final class MasterpieceController extends ChangeNotifier {
  factory MasterpieceController({
    required MasterpieceRemote remote,
    required MasterpieceDraftStore store,
    String Function()? newId,
    MasterpieceGenerationController? generation,
    DateTime Function()? now,
  }) => MasterpieceController._(
    remote,
    store,
    newId ?? _randomId,
    generation,
    now ?? DateTime.now,
  );

  MasterpieceController._(
    this._remote,
    this._store,
    this._newId,
    this.generation,
    this._now,
  ) {
    generation?.addListener(_generationChanged);
    try {
      _draft = _store!.read();
      final recovered = _draft;
      if (recovered != null && !recovered.hasValidSectionKey) {
        if (!recovered.isNew ||
            recovered.stage == MasterpieceIntentStage.accepted) {
          throw const FormatException('Invalid persisted cloud section key');
        }
        _draft = recovered.copyWith(
          sectionKey: _newSectionKey(),
          stage: MasterpieceIntentStage.editing,
          clearIntent: true,
        );
      }
      if (_draft?.stage == MasterpieceIntentStage.submitting) {
        _draft = _draft!.copyWith(stage: MasterpieceIntentStage.uncertain);
      }
      _phase = _draftPhase ?? MasterpiecePhase.loading;
    } catch (_) {
      _storageBlocked = true;
      _errorCode = 'MASTERPIECE_DRAFT_UNREADABLE';
      _phase = MasterpiecePhase.failure;
    }
  }

  MasterpieceController.signedOut()
    : _remote = null,
      _store = null,
      _newId = _randomId,
      generation = null,
      _now = DateTime.now,
      _phase = MasterpiecePhase.signedOut;

  static const _automaticRefreshFreshness = Duration(seconds: 30);
  final MasterpieceRemote? _remote;
  final MasterpieceDraftStore? _store;
  final String Function() _newId;
  final MasterpieceGenerationController? generation;
  final DateTime Function() _now;
  DateTime? _lastSuccessfulReadAt;
  MasterpieceSnapshot? _appliedGenerationSnapshot;
  MasterpiecePhase _phase = MasterpiecePhase.loading;
  MasterpieceSnapshot? _snapshot;
  MasterpieceDraft? _draft;
  String? _errorCode;
  bool _fresh = false;
  bool _disposed = false;
  bool _storageBlocked = false;
  bool _writing = false;
  bool _localTransition = false;
  Future<void>? _readFlight;
  Future<void> _storageTail = Future.value();
  Timer? _draftTimer;

  MasterpiecePhase get phase => _phase;
  MasterpieceSnapshot? get snapshot => _snapshot;
  MasterpieceDraft? get draft => _draft;
  String? get errorCode => _errorCode;
  bool get fresh => _fresh;
  bool get reading => _readFlight != null;
  bool get busy => _writing || _localTransition || reading;
  bool get canRefresh =>
      !_disposed &&
      !_storageBlocked &&
      _remote != null &&
      !busy &&
      generation?.busy != true &&
      (_draft?.intentLocked != true ||
          _draft?.stage == MasterpieceIntentStage.accepted);
  bool get canStartAction =>
      !_disposed &&
      !_storageBlocked &&
      _fresh &&
      (generation?.allowsEditing ?? true) &&
      !busy &&
      _draft == null &&
      _snapshot != null;
  bool get canSave =>
      !_disposed &&
      !busy &&
      !_storageBlocked &&
      _fresh &&
      (generation?.allowsEditing ?? true) &&
      _snapshot != null &&
      _phase == MasterpiecePhase.editing &&
      _draft?.isValid == true &&
      _draft?.hasChanges == true &&
      _matchesBaseline(_draft!, _snapshot!);
  bool get canDiscard =>
      !_disposed && !busy && _draft != null && !_draft!.intentLocked;
  bool get canRebase =>
      !_disposed &&
      !busy &&
      _fresh &&
      _phase == MasterpiecePhase.conflict &&
      _draft != null &&
      !_draft!.isNew &&
      _snapshot?.book.bookId == _draft!.bookId &&
      _snapshot?.chapter(_draft!.sectionKey)?.requiresCopy == false &&
      _snapshot?.chapter(_draft!.sectionKey)?.revision?.part == _draft!.part;
  String? get chatMarkdown =>
      _draft == null && _fresh ? _snapshot?.chatMarkdown : null;

  String get statusMessage {
    if (_errorCode == 'MASTERPIECE_DRAFT_UNREADABLE') {
      return '历史草稿暂时无法读取，已停止写入以保护原始数据。请重启后重试。';
    }
    if (_errorCode == 'MASTERPIECE_DRAFT_STORAGE_FAILED') {
      return '本机草稿保存失败。正文仍保留在当前页面，请先复制备份，再重试。';
    }
    if (_phase == MasterpiecePhase.editing && !_fresh) {
      return '本机草稿已保留，尚未确认云端基线。可继续输入或复制；请重新校验云端后保存。';
    }
    if (_phase == MasterpiecePhase.editing && _errorCode != null) {
      return '保存未被接受，草稿已保留。请检查登录、权限或内容后重试（$_errorCode）。';
    }
    return switch (_phase) {
      MasterpiecePhase.signedOut => '请先登录并完成工作区初始化。',
      MasterpiecePhase.loading => '正在读取云端代表作…',
      MasterpiecePhase.unavailable =>
        _errorCode == 'BOOK_NOT_FOUND'
            ? '云端工作区尚未初始化代表作，暂时不能创建章节。请稍后重试。'
            : '当前账号暂时无法访问云端代表作，请检查登录状态或权限后重试。',
      MasterpiecePhase.failure => '云端代表作读取失败，请检查网络后重试。',
      MasterpiecePhase.empty => '还没有云端章节，可以开始写作或导入历史本地草稿。',
      MasterpiecePhase.reading =>
        _fresh ? '已读取云端版本' : '刷新失败，当前为上次读取内容；刷新成功后才能编辑。',
      MasterpiecePhase.editing => '正在编辑本机草稿，点击“保存到云端”后才会同步。',
      MasterpiecePhase.saving => '正在提交云端，请勿重复提交。离开页面不会取消操作。',
      MasterpiecePhase.uncertain => '提交结果尚未确认。正文与提交编号已保留，请重试同一次提交。',
      MasterpiecePhase.awaitingReadback => '云端已接受提交，正在等待回读确认；不会重复提交。',
      MasterpiecePhase.conflict => '云端版本已变化，本机草稿已保留。请读取最新内容并比较后再继续。',
    };
  }

  Future<void> refresh({bool force = true}) {
    if (_disposed ||
        _remote == null ||
        _storageBlocked ||
        _writing ||
        _localTransition) {
      return Future.value();
    }
    final existing = _readFlight;
    if (existing != null) return existing;
    if (_draft?.stage == MasterpieceIntentStage.uncertain) {
      return Future.value();
    }
    final lastReadAt = _lastSuccessfulReadAt;
    if (!force &&
        _fresh &&
        _errorCode == null &&
        _snapshot != null &&
        _draft == null &&
        generation?.intent == null &&
        (generation == null || generation!.unlocked) &&
        lastReadAt != null) {
      final age = _now().toUtc().difference(lastReadAt);
      if (!age.isNegative && age < _automaticRefreshFreshness) {
        return Future.value();
      }
    }
    final flight = _readAndReconcile();
    _readFlight = flight;
    _notify();
    return flight.whenComplete(() {
      if (identical(_readFlight, flight)) _readFlight = null;
      _notify();
    });
  }

  Future<void> _readAndReconcile() async {
    generation?.invalidateEligibility();
    await _read();
    if (_disposed) return;
    await generation?.reconcile(
      snapshot: _fresh ? _snapshot : null,
      documentIdle: _fresh && _draft == null && !_writing && !_localTransition,
    );
    if (!_disposed && _fresh && _errorCode == null) {
      _lastSuccessfulReadAt = _now().toUtc();
    }
  }

  void _generationChanged() {
    if (_disposed) return;
    final confirmed = generation?.confirmedSnapshot;
    if (confirmed != null &&
        !identical(confirmed, _appliedGenerationSnapshot)) {
      _appliedGenerationSnapshot = confirmed;
      if (_draft == null) {
        _snapshot = confirmed;
        _fresh = true;
        _errorCode = null;
        _phase = _readerPhase;
      }
    }
    _notify();
  }

  Future<void> _read() async {
    if (_draft == null && _snapshot == null) _phase = MasterpiecePhase.loading;
    try {
      final next = await _remote!.read().timeout(const Duration(seconds: 40));
      if (_disposed) return;
      _snapshot = next;
      _fresh = true;
      _errorCode = null;
      final current = _draft;
      if (current?.stage == MasterpieceIntentStage.accepted) {
        if (next.book.bookId != current!.bookId ||
            next.chapter(current.sectionKey) == null) {
          _phase = MasterpiecePhase.awaitingReadback;
          _errorCode = 'MASTERPIECE_READBACK_PENDING';
          _fresh = false;
          return;
        }
        final acceptedId = current.acceptedRevisionId;
        final chapter = next.chapter(current.sectionKey)!;
        final visibleId = chapter.section.currentPartRevisionIds[current.part];
        if (visibleId == null) {
          _phase = MasterpiecePhase.awaitingReadback;
          _errorCode = 'MASTERPIECE_READBACK_PENDING';
          _fresh = false;
          return;
        }
        if (acceptedId != null && visibleId != acceptedId) {
          final accepted = await _remote
              .readRevision(current.sectionKey, current.part, acceptedId)
              .timeout(const Duration(seconds: 20));
          if (_disposed) return;
          final visible = chapter.revision?.partRevisionId == visibleId
              ? chapter.revision!
              : await _remote
                    .readRevision(current.sectionKey, current.part, visibleId)
                    .timeout(const Duration(seconds: 20));
          if (_disposed) return;
          if (visible.revision < accepted.revision) {
            _phase = MasterpiecePhase.awaitingReadback;
            _errorCode = 'MASTERPIECE_READBACK_PENDING';
            _fresh = false;
            return;
          }
        }
        if (!await _persist(null)) return;
        if (_disposed) return;
        _draft = null;
      } else if (current != null && !_matchesBaseline(current, next)) {
        _draft = current.copyWith(
          stage: MasterpieceIntentStage.conflict,
          clearIntent: true,
        );
        await _persist(_draft);
        if (_disposed) return;
      }
      _phase = _draftPhase ?? _readerPhase;
    } catch (error) {
      if (_disposed) return;
      _fresh = false;
      final failure = error is MasterpieceRemoteException ? error : null;
      _errorCode = failure?.code ?? 'MASTERPIECE_READ_FAILED';
      _phase =
          _draftPhase ??
          (failure?.unavailable == true
              ? MasterpiecePhase.unavailable
              : _snapshot == null
              ? MasterpiecePhase.failure
              : MasterpiecePhase.reading);
    }
    _notify();
  }

  bool beginNew({String title = '', String markdown = ''}) {
    if (!canStartAction) return false;
    _draft = MasterpieceDraft(
      bookId: _snapshot!.book.bookId,
      sectionKey: _newSectionKey(),
      title: title,
      markdown: markdown,
    );
    _phase = MasterpiecePhase.editing;
    _scheduleDraft();
    _notify();
    return true;
  }

  bool beginEdit(MasterpieceChapter chapter) {
    if (!canStartAction ||
        chapter.requiresCopy ||
        !identical(_snapshot?.chapter(chapter.section.sectionKey), chapter)) {
      return false;
    }
    final revision = chapter.revision;
    if (revision == null) return false;
    _draft = _draftFor(chapter, revision.contentMarkdown);
    _phase = MasterpiecePhase.editing;
    _scheduleDraft();
    _notify();
    return true;
  }

  bool beginCopy(MasterpieceChapter chapter) {
    if (!canStartAction ||
        chapter.revision == null ||
        !identical(_snapshot?.chapter(chapter.section.sectionKey), chapter)) {
      return false;
    }
    final revision = chapter.revision!;
    _draft = MasterpieceDraft(
      bookId: _snapshot!.book.bookId,
      sectionKey: _newSectionKey(),
      title: '${chapter.section.title} · 续写',
      markdown: revision.contentMarkdown,
      part: revision.part,
      sourceRefs: revision.sourceRefs,
      managedSourceRefs: revision.managedSourceRefs,
      resourceRefs: chapter.section.resourceRefs,
    );
    _phase = MasterpiecePhase.editing;
    _scheduleDraft();
    _notify();
    return true;
  }

  void edit({String? title, String? markdown}) {
    if (_disposed ||
        !(generation?.allowsEditing ?? true) ||
        _phase != MasterpiecePhase.editing ||
        busy ||
        _draft == null) {
      return;
    }
    _draft = _draft!.copyWith(
      title: _draft!.isNew ? title : null,
      markdown: markdown,
      clearIntent: true,
    );
    _scheduleDraft();
    _notify();
  }

  Future<bool> flushDraft() {
    _draftTimer?.cancel();
    final current = _draft;
    if (_writing || _localTransition || current?.intentLocked == true) {
      return _storageTail.then(
        (_) => _errorCode != 'MASTERPIECE_DRAFT_STORAGE_FAILED',
      );
    }
    return current == null ? Future.value(true) : _persist(current);
  }

  Future<void> save() async {
    final uncertain = _phase == MasterpiecePhase.uncertain;
    if (_disposed ||
        busy ||
        _remote == null ||
        _draft == null ||
        (!uncertain && !canSave)) {
      return;
    }
    final intent = _draft!.copyWith(
      stage: MasterpieceIntentStage.submitting,
      idempotencyKey: uncertain
          ? _draft!.idempotencyKey
          : 'masterpiece-${_newId()}',
    );
    _draftTimer?.cancel();
    _writing = true;
    _draft = intent;
    _phase = MasterpiecePhase.saving;
    _errorCode = null;
    _notify();
    if (!await _persist(intent)) {
      _writing = false;
      _draft = intent.copyWith(
        stage: uncertain
            ? MasterpieceIntentStage.uncertain
            : MasterpieceIntentStage.editing,
      );
      _phase = _draftPhase!;
      _notify();
      return;
    }
    if (_disposed) return;
    try {
      final receipt = await _remote
          .write(intent)
          .timeout(const Duration(seconds: 35));
      if (_disposed) return;
      final accepted = intent.copyWith(
        stage: MasterpieceIntentStage.accepted,
        acceptedRevisionId: receipt.revisionId,
      );
      _draft = accepted;
      _phase = MasterpiecePhase.awaitingReadback;
      await _persist(accepted);
      _writing = false;
      if (_disposed) return;
      await refresh();
    } catch (error) {
      if (_disposed) return;
      final failure = error is MasterpieceRemoteException ? error : null;
      _errorCode = failure?.code ?? 'MASTERPIECE_SUBMISSION_UNKNOWN';
      final ambiguous = uncertain || failure == null || failure.ambiguous;
      _draft = intent.copyWith(
        stage: ambiguous
            ? MasterpieceIntentStage.uncertain
            : failure.isConflict
            ? MasterpieceIntentStage.conflict
            : MasterpieceIntentStage.editing,
        clearIntent: !ambiguous,
      );
      _phase = _draftPhase!;
      _fresh = false;
      await _persist(_draft);
      _writing = false;
      if (_disposed) return;
      if (_phase == MasterpiecePhase.conflict) await refresh();
      _notify();
    }
  }

  Future<void> discard() async {
    if (!canDiscard) return;
    _draftTimer?.cancel();
    _localTransition = true;
    _notify();
    final persisted = await _persist(null);
    _localTransition = false;
    if (!persisted || _disposed) {
      _notify();
      return;
    }
    _draft = null;
    _phase = _snapshot == null ? MasterpiecePhase.loading : _readerPhase;
    _notify();
    await refresh();
  }

  Future<void> rebaseAfterConfirmation({
    required String reviewedRevisionId,
  }) async {
    if (!canRebase) return;
    final current = _draft!;
    final chapter = _snapshot!.chapter(current.sectionKey)!;
    if (chapter.revision!.partRevisionId != reviewedRevisionId) return;
    final rebased = _draftFor(chapter, current.markdown);
    _localTransition = true;
    _notify();
    final persisted = await _persist(rebased);
    _localTransition = false;
    if (!persisted || _disposed) {
      _notify();
      return;
    }
    _draft = rebased;
    _phase = MasterpiecePhase.editing;
    _notify();
  }

  Future<bool> prepareChat() async {
    if (_draft != null || _storageBlocked || _disposed || _remote == null) {
      return false;
    }
    await refresh();
    return canStartAction;
  }

  MasterpieceDraft _draftFor(MasterpieceChapter chapter, String markdown) {
    final revision = chapter.revision!;
    return MasterpieceDraft(
      bookId: _snapshot!.book.bookId,
      sectionKey: chapter.section.sectionKey,
      part: revision.part,
      title: chapter.section.title,
      markdown: markdown,
      baseMarkdown: revision.contentMarkdown,
      baseRevisionId: revision.partRevisionId,
      etag: revision.etag,
      sourceRefs: revision.sourceRefs,
      resourceRefs: chapter.section.resourceRefs,
    );
  }

  String _newSectionKey() {
    final suffix = _newId();
    return 'chapter-${suffix.substring(0, min(suffix.length, 24))}';
  }

  bool _matchesBaseline(MasterpieceDraft draft, MasterpieceSnapshot snapshot) {
    if (snapshot.book.bookId != draft.bookId) return false;
    final chapter = snapshot.chapter(draft.sectionKey);
    if (draft.isNew) return chapter == null;
    return chapter?.revision?.partRevisionId == draft.baseRevisionId &&
        chapter?.revision?.etag == draft.etag;
  }

  MasterpiecePhase get _readerPhase => _snapshot!.chapters.isEmpty
      ? MasterpiecePhase.empty
      : MasterpiecePhase.reading;

  MasterpiecePhase? get _draftPhase => switch (_draft?.stage) {
    null => null,
    MasterpieceIntentStage.editing => MasterpiecePhase.editing,
    MasterpieceIntentStage.submitting => MasterpiecePhase.saving,
    MasterpieceIntentStage.uncertain => MasterpiecePhase.uncertain,
    MasterpieceIntentStage.accepted => MasterpiecePhase.awaitingReadback,
    MasterpieceIntentStage.conflict => MasterpiecePhase.conflict,
  };

  void _scheduleDraft() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(flushDraft());
    });
  }

  Future<bool> _persist(MasterpieceDraft? value) async {
    final store = _store;
    if (store == null) return false;
    final operation = _storageTail.then(
      (_) => value == null ? store.clear() : store.write(value),
    );
    _storageTail = operation.catchError((Object _) {});
    try {
      await operation;
      return true;
    } catch (_) {
      if (!_disposed) {
        _errorCode = 'MASTERPIECE_DRAFT_STORAGE_FAILED';
        _notify();
      }
      return false;
    }
  }

  void _notify() {
    if (!_disposed) {
      generation?.setDocumentIdle(
        _draft == null && !_writing && !_localTransition,
      );
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_draft != null) unawaited(flushDraft());
    _disposed = true;
    generation?.removeListener(_generationChanged);
    generation?.dispose();
    super.dispose();
  }
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
