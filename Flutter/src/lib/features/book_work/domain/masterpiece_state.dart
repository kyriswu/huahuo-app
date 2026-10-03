import 'package:huahuo_api/huahuo_api.dart';

enum MasterpiecePhase {
  signedOut,
  loading,
  unavailable,
  failure,
  empty,
  reading,
  editing,
  saving,
  uncertain,
  awaitingReadback,
  conflict,
}

enum MasterpieceIntentStage {
  editing,
  submitting,
  uncertain,
  accepted,
  conflict,
}

final class MasterpieceChapter {
  const MasterpieceChapter({required this.section, this.revision});

  final SharedBookSection section;
  final SharedManagedPartRevision? revision;
  bool get requiresCopy => revision?.managedSourceRefs.isNotEmpty == true;
}

final class MasterpieceSnapshot {
  MasterpieceSnapshot({
    required this.book,
    required Iterable<MasterpieceChapter> chapters,
  }) : chapters = List.unmodifiable(chapters);

  final SharedBook book;
  final List<MasterpieceChapter> chapters;

  MasterpieceChapter? chapter(String key) {
    for (final chapter in chapters) {
      if (chapter.section.sectionKey == key) return chapter;
    }
    return null;
  }

  String get chatMarkdown {
    final full = <String>[
      '# ${book.current.title}',
      '云端 Book：${book.bookId}；Book 版本：${book.currentBookRevisionId}。',
      '以下是云端固定版本快照，不是写入授权或保存回执。修改建议须经正式章节写入并回读后才生效。',
      for (final chapter in chapters) ...[
        '## ${chapter.section.title}',
        'sectionKey=${chapter.section.sectionKey}; part=${chapter.revision?.part ?? "missing"}; partRevisionId=${chapter.revision?.partRevisionId ?? "missing"}',
        chapter.revision?.contentMarkdown ?? '此章节暂无可读取的正文。',
      ],
    ].join('\n\n');
    if (full.length <= 11000) return full;
    final boundary = full.codeUnitAt(10999);
    final end = boundary >= 0xd800 && boundary <= 0xdbff ? 10999 : 11000;
    return '${full.substring(0, end)}\n\n[长文快照已省略后续内容；省略不代表删除，请勿据此覆盖整本书。]';
  }
}

final class MasterpieceDraft {
  const MasterpieceDraft({
    required this.bookId,
    required this.sectionKey,
    required this.title,
    required this.markdown,
    this.part = 'raw',
    this.baseMarkdown,
    this.baseRevisionId,
    this.etag,
    this.sourceRefs = const [],
    this.resourceRefs = const [],
    this.managedSourceRefs = const [],
    this.stage = MasterpieceIntentStage.editing,
    this.idempotencyKey,
    this.acceptedRevisionId,
  });

  final String bookId;
  final String sectionKey;
  final String title;
  final String markdown;
  final String part;
  final String? baseMarkdown;
  final String? baseRevisionId;
  final String? etag;
  final List<SharedNotePartSourceRef> sourceRefs;
  final List<SharedManagedResourceRef> resourceRefs;
  final List<SharedManagedLineageRef> managedSourceRefs;
  final MasterpieceIntentStage stage;
  final String? idempotencyKey;
  final String? acceptedRevisionId;

  bool get isNew => baseRevisionId == null;
  bool get hasValidSectionKey =>
      RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(sectionKey);
  bool get isValid =>
      hasValidSectionKey &&
      title.trim().isNotEmpty &&
      markdown.trim().isNotEmpty;
  bool get hasChanges => isNew || markdown != baseMarkdown;
  bool get intentLocked =>
      stage == MasterpieceIntentStage.submitting ||
      stage == MasterpieceIntentStage.uncertain ||
      stage == MasterpieceIntentStage.accepted;

  MasterpieceDraft copyWith({
    String? sectionKey,
    String? title,
    String? markdown,
    MasterpieceIntentStage? stage,
    String? idempotencyKey,
    String? acceptedRevisionId,
    bool clearIntent = false,
  }) => MasterpieceDraft(
    bookId: bookId,
    sectionKey: sectionKey ?? this.sectionKey,
    part: part,
    title: title ?? this.title,
    markdown: markdown ?? this.markdown,
    baseMarkdown: baseMarkdown,
    baseRevisionId: baseRevisionId,
    etag: etag,
    sourceRefs: sourceRefs,
    resourceRefs: resourceRefs,
    managedSourceRefs: managedSourceRefs,
    stage: stage ?? this.stage,
    idempotencyKey: clearIntent ? null : idempotencyKey ?? this.idempotencyKey,
    acceptedRevisionId: clearIntent
        ? null
        : acceptedRevisionId ?? this.acceptedRevisionId,
  );

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'sectionKey': sectionKey,
    'part': part,
    'title': title,
    'markdown': markdown,
    'baseMarkdown': baseMarkdown,
    'baseRevisionId': baseRevisionId,
    'etag': etag,
    'sourceRefs': sourceRefs.map((reference) => reference.toJson()).toList(),
    'resourceRefs': resourceRefs
        .map((reference) => reference.toJson())
        .toList(),
    'managedSourceRefs': managedSourceRefs
        .map((reference) => reference.toJson())
        .toList(),
    'stage': stage.name,
    'idempotencyKey': idempotencyKey,
    'acceptedRevisionId': acceptedRevisionId,
  };

  factory MasterpieceDraft.fromJson(Map<String, Object?> json) {
    final draft = MasterpieceDraft(
      bookId: json['bookId'] as String,
      sectionKey: json['sectionKey'] as String,
      title: json['title'] as String,
      markdown: json['markdown'] as String,
      part: json['part'] as String,
      baseMarkdown: json['baseMarkdown'] as String?,
      baseRevisionId: json['baseRevisionId'] as String?,
      etag: json['etag'] as String?,
      sourceRefs: (json['sourceRefs'] as List)
          .map(
            (value) => SharedNotePartSourceRef.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          )
          .toList(),
      resourceRefs: (json['resourceRefs'] as List)
          .map(
            (value) => SharedManagedResourceRef.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          )
          .toList(),
      managedSourceRefs: ((json['managedSourceRefs'] as List?) ?? const [])
          .map(
            (value) => SharedManagedLineageRef.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          )
          .toList(),
      stage: MasterpieceIntentStage.values.byName(json['stage'] as String),
      idempotencyKey: json['idempotencyKey'] as String?,
      acceptedRevisionId: json['acceptedRevisionId'] as String?,
    );
    if (draft.bookId.trim().isEmpty ||
        draft.sectionKey.trim().isEmpty ||
        !const {'raw', 'outline', 'germination'}.contains(draft.part) ||
        (!draft.isNew && draft.managedSourceRefs.isNotEmpty) ||
        (!draft.isNew &&
            (draft.etag?.isNotEmpty != true || draft.baseMarkdown == null)) ||
        (draft.intentLocked && draft.idempotencyKey?.isNotEmpty != true) ||
        (!draft.isNew &&
            draft.stage == MasterpieceIntentStage.accepted &&
            draft.acceptedRevisionId?.isNotEmpty != true)) {
      throw const FormatException('Invalid representative-work draft identity');
    }
    return draft;
  }
}

final class MasterpieceRemoteException implements Exception {
  const MasterpieceRemoteException(
    this.code, {
    this.status,
    this.ambiguous = false,
  });
  final String code;
  final int? status;
  final bool ambiguous;
  bool get isConflict => status == 409 || status == 412;
  bool get unavailable =>
      status == 401 ||
      status == 403 ||
      code == 'BOOK_NOT_FOUND' ||
      code == 'API_BASE_URL_UNCONFIGURED';
}

abstract interface class MasterpieceRemote {
  Future<MasterpieceSnapshot> read();
  Future<SharedManagedPartRevision> readRevision(
    String sectionKey,
    String part,
    String revisionId,
  );
  Future<SharedWorkspaceContentEvent> write(MasterpieceDraft intent);
}

abstract interface class MasterpieceDraftStore {
  MasterpieceDraft? read();
  Future<void> write(MasterpieceDraft draft);
  Future<void> clear();
}
