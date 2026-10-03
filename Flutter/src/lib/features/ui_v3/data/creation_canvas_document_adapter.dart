import 'package:huahuo_editor/huahuo_editor.dart';

import '../domain/creation_canvas_draft.dart';
import '../domain/feed_item_models.dart';

abstract final class CreationCanvasDocumentAdapter {
  static HuahuoDocumentSnapshot? snapshotFromDraft({
    required String id,
    required CreationCanvasDraft draft,
    String? summaryMarkdown,
    String? sproutMarkdown,
    Iterable<HuahuoAiAnnotation>? aiAnnotations,
  }) {
    final documentJson = draft.documentJson;
    if (draft.unreadableStructuredDocument ||
        documentJson == null ||
        documentJson.trim().isEmpty ||
        draft.documentFormatVersion !=
            CreationCanvasDraft.currentDocumentFormatVersion) {
      return null;
    }
    return HuahuoDocumentSnapshot(
      id: id,
      title: draft.title,
      deltaJson: documentJson,
      markdownProjection: draft.markdown,
      linkedMaterials: draft.linkedMaterials.map(_toSharedMaterial),
      sourceTopicId: draft.sourceTopicId,
      sourceTopicTitle: draft.sourceTitle,
      revision: draft.revision,
      createdAt: draft.createdAt,
      modifiedAt: draft.updatedAt,
      summaryMarkdown: summaryMarkdown ?? draft.summaryMarkdown,
      sproutMarkdown: sproutMarkdown ?? draft.sproutMarkdown,
      aiAnnotations: aiAnnotations ?? draft.aiAnnotations,
    );
  }

  static CreationCanvasDraft draftFromSnapshot(
    HuahuoDocumentSnapshot snapshot,
  ) {
    return CreationCanvasDraft(
      title: snapshot.title,
      markdown:
          snapshot.markdownProjection ??
          HuahuoDocumentCodec.deltaToMarkdown(
            HuahuoDocumentCodec.decode(snapshot.deltaJson),
          ),
      documentJson: snapshot.deltaJson,
      documentFormatVersion: CreationCanvasDraft.currentDocumentFormatVersion,
      linkedMaterials: snapshot.linkedMaterials.map(_toMobileMaterial),
      sourceTopicId: snapshot.sourceTopicId,
      sourceTitle: snapshot.sourceTopicTitle,
      summaryMarkdown: snapshot.summaryMarkdown,
      sproutMarkdown: snapshot.sproutMarkdown,
      aiAnnotations: snapshot.aiAnnotations,
      revision: snapshot.revision,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.modifiedAt,
    );
  }

  static HuahuoLinkedMaterialRef _toSharedMaterial(
    V3LinkedMaterialRef material,
  ) => HuahuoLinkedMaterialRef(
    id: material.id,
    source: material.source.name,
    title: material.title,
    summary: material.summary,
  );

  static V3LinkedMaterialRef _toMobileMaterial(
    HuahuoLinkedMaterialRef material,
  ) {
    V3MaterialSource? source;
    for (final candidate in V3MaterialSource.values) {
      if (candidate.name == material.source) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      throw FormatException(
        'Unsupported linked material source: ${material.source}',
      );
    }
    return V3LinkedMaterialRef(
      id: material.id,
      source: source,
      title: material.title,
      summary: material.summary,
    );
  }
}
