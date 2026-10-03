import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/feed_item_models.dart';
import 'knowledge_library_controller.dart';

enum NoteAppendSource {
  monologue,
  meeting,
  internalRecording,
  link,
  phoneAudio,
  localRecording,
  recordingCard,
  document,
  media,
  relatedNote,
}

extension NoteAppendSourceX on NoteAppendSource {
  String get routeName => switch (this) {
    NoteAppendSource.internalRecording => 'internal-recording',
    NoteAppendSource.phoneAudio => 'phone-audio',
    NoteAppendSource.localRecording => 'local-recording',
    NoteAppendSource.recordingCard => 'recording-card',
    NoteAppendSource.relatedNote => 'related-note',
    _ => name,
  };

  String get label => switch (this) {
    NoteAppendSource.monologue => '独白',
    NoteAppendSource.meeting => '会议',
    NoteAppendSource.internalRecording => '内录',
    NoteAppendSource.link => '链接',
    NoteAppendSource.phoneAudio => '手机文件',
    NoteAppendSource.localRecording => '本地录音',
    NoteAppendSource.recordingCard => '录音卡文件',
    NoteAppendSource.document => '文档',
    NoteAppendSource.media => '相册',
    NoteAppendSource.relatedNote => '已有笔记',
  };

  static NoteAppendSource? fromRoute(String value) {
    for (final source in NoteAppendSource.values) {
      if (source.routeName == value) return source;
    }
    return null;
  }
}

enum NoteAppendStatus { uploading, analyzing, completed, failed }

@immutable
final class NoteAppendRequest {
  const NoteAppendRequest({
    required this.targetNoteId,
    required this.source,
    required this.title,
    required this.idempotencyKey,
    this.baseRevision,
    this.referenceId,
  });

  final String targetNoteId;
  final NoteAppendSource source;
  final String title;
  final String idempotencyKey;
  final int? baseRevision;
  final String? referenceId;
}

@immutable
final class V3AppendMaterial {
  const V3AppendMaterial({
    required this.id,
    required this.targetNoteId,
    required this.source,
    required this.title,
    required this.status,
    required this.addedAt,
    required this.updatedAt,
    required this.isDemo,
    this.referenceId,
    this.summary,
    this.errorCode,
  });

  final String id;
  final String targetNoteId;
  final NoteAppendSource source;
  final String title;
  final NoteAppendStatus status;
  final DateTime addedAt;
  final DateTime updatedAt;
  final bool isDemo;
  final String? referenceId;
  final String? summary;
  final String? errorCode;

  V3AppendMaterial copyWith({
    NoteAppendStatus? status,
    DateTime? updatedAt,
    String? summary,
    String? errorCode,
    bool? isDemo,
    bool clearError = false,
  }) {
    return V3AppendMaterial(
      id: id,
      targetNoteId: targetNoteId,
      source: source,
      title: title,
      status: status ?? this.status,
      addedAt: addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDemo: isDemo ?? this.isDemo,
      referenceId: referenceId,
      summary: summary ?? this.summary,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

typedef NoteAppendProgress = void Function(NoteAppendStatus status);

@immutable
final class NoteAppendPortResult {
  const NoteAppendPortResult({
    required this.ok,
    this.summary,
    this.errorCode,
    this.isDemo = false,
    this.updatedParentNote,
  });

  final bool ok;
  final String? summary;
  final String? errorCode;
  final bool isDemo;
  final V3FeedItem? updatedParentNote;
}

abstract interface class NoteAppendPort {
  bool get isDemo;

  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  });
}

final class UnavailableNoteAppendPort implements NoteAppendPort {
  const UnavailableNoteAppendPort();

  @override
  bool get isDemo => false;

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    return const NoteAppendPortResult(
      ok: false,
      errorCode: 'NOTE_APPEND_BACKEND_UNAVAILABLE',
    );
  }
}

final class MockNoteAppendPort implements NoteAppendPort {
  const MockNoteAppendPort({
    this.uploadDelay = const Duration(milliseconds: 260),
    this.analysisDelay = const Duration(milliseconds: 480),
  });

  final Duration uploadDelay;
  final Duration analysisDelay;

  @override
  bool get isDemo => true;

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    await Future<void>.delayed(uploadDelay);
    onProgress(NoteAppendStatus.analyzing);
    await Future<void>.delayed(analysisDelay);
    return NoteAppendPortResult(
      ok: true,
      isDemo: true,
      summary: '${request.source.label}资料已在本次会话中关联，摘要更新等待后端接口。',
    );
  }
}

final class NoteAppendController extends ChangeNotifier {
  NoteAppendController({
    required KnowledgeLibraryController knowledgeLibrary,
    required NoteAppendPort port,
    DateTime Function()? now,
  }) : _knowledgeLibrary = knowledgeLibrary,
       _port = port,
       _now = now ?? DateTime.now;

  final KnowledgeLibraryController _knowledgeLibrary;
  final NoteAppendPort _port;
  final DateTime Function() _now;
  final List<V3AppendMaterial> _items = <V3AppendMaterial>[];
  final Map<String, NoteAppendRequest> _requests =
      <String, NoteAppendRequest>{};
  int _sequence = 0;
  int _sessionGeneration = 0;
  bool _disposed = false;

  List<V3AppendMaterial> itemsFor(String noteId) {
    final items = _items.where((item) => item.targetNoteId == noteId).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return List<V3AppendMaterial>.unmodifiable(items);
  }

  bool canAppendTo(String noteId) {
    if (_disposed) return false;
    final note = _knowledgeLibrary.noteForId(noteId);
    return note != null && note.ownership == V3NoteOwnership.mine;
  }

  Future<V3AppendMaterial?> submit({
    required String targetNoteId,
    required NoteAppendSource source,
    required String title,
    String? referenceId,
  }) async {
    if (_disposed) return null;
    final safeTitle = title.trim();
    final target = _knowledgeLibrary.noteForId(targetNoteId);
    if (target == null || target.isReadOnly || safeTitle.isEmpty) return null;
    final now = _now();
    final sequence = ++_sequence;
    final generation = _sessionGeneration;
    final id = 'append-${now.microsecondsSinceEpoch}-$sequence';
    final request = NoteAppendRequest(
      targetNoteId: targetNoteId,
      source: source,
      title: safeTitle,
      referenceId: referenceId,
      baseRevision: target.remoteRevision,
      idempotencyKey: _appendIdempotencyKey(
        targetNoteId: targetNoteId,
        source: source,
        title: safeTitle,
        referenceId: referenceId,
      ),
    );
    final item = V3AppendMaterial(
      id: id,
      targetNoteId: targetNoteId,
      source: source,
      title: safeTitle,
      status: NoteAppendStatus.uploading,
      addedAt: now,
      updatedAt: now,
      isDemo: _port.isDemo,
      referenceId: referenceId,
    );
    _requests[id] = request;
    _items.add(item);
    notifyListeners();
    return _run(id, request, generation);
  }

  Future<V3AppendMaterial?> retry(String itemId) async {
    if (_disposed) return null;
    final request = _requests[itemId];
    final index = _items.indexWhere((item) => item.id == itemId);
    if (request == null || index == -1 || !canAppendTo(request.targetNoteId)) {
      return null;
    }
    _items[index] = _items[index].copyWith(
      status: NoteAppendStatus.uploading,
      updatedAt: _now(),
      clearError: true,
    );
    notifyListeners();
    return _run(itemId, request, _sessionGeneration);
  }

  void clearSession() {
    _sessionGeneration += 1;
    if (_items.isEmpty && _requests.isEmpty) return;
    _items.clear();
    _requests.clear();
    if (!_disposed) notifyListeners();
  }

  Future<V3AppendMaterial?> _run(
    String itemId,
    NoteAppendRequest request,
    int generation,
  ) async {
    try {
      final result = await _port.submit(
        request,
        onProgress: (status) => _setStatus(itemId, status, generation),
      );
      if (_disposed || generation != _sessionGeneration) return null;
      final index = _items.indexWhere((item) => item.id == itemId);
      if (index == -1) return null;
      var ok = result.ok;
      var errorCode = result.errorCode;
      if (result.isDemo != _port.isDemo) {
        ok = false;
        errorCode = 'NOTE_APPEND_PORT_MODE_MISMATCH';
      }
      if (ok && !_port.isDemo) {
        final updatedParent = result.updatedParentNote;
        if (updatedParent == null) {
          ok = false;
          errorCode = 'NOTE_APPEND_UPDATED_PARENT_MISSING';
        } else if (updatedParent.id != request.targetNoteId) {
          ok = false;
          errorCode = 'NOTE_APPEND_UPDATED_PARENT_MISMATCH';
        } else {
          _knowledgeLibrary.mergeRemoteNote(updatedParent);
        }
      }
      _items[index] = _items[index].copyWith(
        status: ok ? NoteAppendStatus.completed : NoteAppendStatus.failed,
        updatedAt: _now(),
        summary: result.summary,
        errorCode:
            errorCode ?? (ok ? null : 'NOTE_APPEND_DEMO_SUBMISSION_FAILED'),
        isDemo: _port.isDemo,
        clearError: ok,
      );
      notifyListeners();
      return _items[index];
    } catch (_) {
      if (_disposed || generation != _sessionGeneration) return null;
      final index = _items.indexWhere((item) => item.id == itemId);
      if (index == -1) return null;
      _items[index] = _items[index].copyWith(
        status: NoteAppendStatus.failed,
        updatedAt: _now(),
        errorCode: 'NOTE_APPEND_PORT_FAILED',
      );
      notifyListeners();
      return _items[index];
    }
  }

  void _setStatus(String itemId, NoteAppendStatus status, int generation) {
    if (_disposed || generation != _sessionGeneration) return;
    final index = _items.indexWhere((item) => item.id == itemId);
    if (index == -1) return;
    _items[index] = _items[index].copyWith(
      status: status,
      updatedAt: _now(),
      clearError: true,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionGeneration += 1;
    _items.clear();
    _requests.clear();
    super.dispose();
  }
}

String _appendIdempotencyKey({
  required String targetNoteId,
  required NoteAppendSource source,
  required String title,
  String? referenceId,
}) {
  final identity = referenceId?.trim().isNotEmpty == true
      ? referenceId!.trim()
      : title.trim();
  final digest = sha256.convert(utf8.encode(identity)).toString();
  return '$targetNoteId:${source.routeName}:${digest.substring(0, 24)}';
}
