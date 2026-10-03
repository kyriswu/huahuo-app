import '../contracts/contract_models.dart';

typedef WorkspaceHNotePartReader =
    Future<SharedHNotePartView> Function({
      required String noteId,
      required String part,
      required String partRevisionId,
    });

Future<SharedHNote> hydrateWorkspaceHNoteParts(
  SharedHNote note, {
  required WorkspaceHNotePartReader readPart,
}) async {
  final rawPartRevisionId = _nonEmpty(note.raw.partRevisionId);
  if (rawPartRevisionId == null) {
    throw const FormatException('rawPartRevisionId must be non-empty');
  }
  if (hasEmbeddedWorkspaceHNoteParts(note)) return note;
  final parts = await Future.wait<SharedHNotePart>(<Future<SharedHNotePart>>[
    _readWorkspaceHNotePart(
      note,
      part: 'raw',
      partRevisionId: rawPartRevisionId,
      readPart: readPart,
    ),
    _readOptionalWorkspaceHNotePart(
      note,
      part: 'outline',
      partRevisionId: note.outline.partRevisionId,
      readPart: readPart,
    ),
    _readOptionalWorkspaceHNotePart(
      note,
      part: 'germination',
      partRevisionId: note.germination.partRevisionId,
      readPart: readPart,
    ),
  ]);
  return SharedHNote(
    noteId: note.noteId,
    workspaceId: note.workspaceId,
    sourceKind: note.sourceKind,
    folderId: note.folderId,
    title: note.title,
    state: note.state,
    noteRevisionId: note.noteRevisionId,
    raw: parts[0],
    outline: parts[1],
    germination: parts[2],
    resourceRefs: note.resourceRefs,
    etag: note.etag,
    contentCursor: note.contentCursor,
    activeDerivedTasks: note.activeDerivedTasks,
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
  );
}

Future<SharedHNotePart> _readOptionalWorkspaceHNotePart(
  SharedHNote note, {
  required String part,
  required String partRevisionId,
  required WorkspaceHNotePartReader readPart,
}) {
  final revisionId = _nonEmpty(partRevisionId);
  if (revisionId == null) {
    return Future<SharedHNotePart>.value(
      const SharedHNotePart(partRevisionId: '', markdown: '', contentHash: ''),
    );
  }
  return _readWorkspaceHNotePart(
    note,
    part: part,
    partRevisionId: revisionId,
    readPart: readPart,
  );
}

Future<SharedHNotePart> _readWorkspaceHNotePart(
  SharedHNote note, {
  required String part,
  required String partRevisionId,
  required WorkspaceHNotePartReader readPart,
}) async {
  final view = await readPart(
    noteId: note.noteId,
    part: part,
    partRevisionId: partRevisionId,
  );
  if (view.noteId != note.noteId ||
      view.part != part ||
      view.partRevisionId != partRevisionId ||
      view.contentHash.trim().isEmpty) {
    throw const FormatException('HNote part does not match its formal head');
  }
  return SharedHNotePart(
    partRevisionId: view.partRevisionId,
    markdown: view.markdown,
    contentHash: view.contentHash,
  );
}

bool hasEmbeddedWorkspaceHNoteParts(SharedHNote note) =>
    _nonEmpty(note.raw.partRevisionId) != null &&
    note.raw.contentHash.trim().isNotEmpty &&
    _isEmbeddedOrAbsentDerivedPart(note.outline) &&
    _isEmbeddedOrAbsentDerivedPart(note.germination);

bool _isEmbeddedOrAbsentDerivedPart(SharedHNotePart part) {
  if (_nonEmpty(part.partRevisionId) != null) {
    return part.contentHash.trim().isNotEmpty;
  }
  return part.partRevisionId.isEmpty &&
      part.markdown.isEmpty &&
      part.contentHash.isEmpty;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
