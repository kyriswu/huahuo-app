import 'package:flutter/foundation.dart';

import 'feed_item_models.dart';
import 'v3_markdown_outline.dart';

enum V3KnowledgeOutlineStage { raw, summary, sprout }

extension V3KnowledgeOutlineStageX on V3KnowledgeOutlineStage {
  String get label => switch (this) {
    V3KnowledgeOutlineStage.raw => '原始',
    V3KnowledgeOutlineStage.summary => '纲要',
    V3KnowledgeOutlineStage.sprout => '深度洞察',
  };

  String get routeValue => name;

  V3ContentStage get contentStage => switch (this) {
    V3KnowledgeOutlineStage.raw => V3ContentStage.raw,
    V3KnowledgeOutlineStage.summary => V3ContentStage.summary,
    V3KnowledgeOutlineStage.sprout => V3ContentStage.sprout,
  };
}

typedef V3KnowledgeOutlineHeading = V3MarkdownOutlineNode;

@immutable
final class V3KnowledgeOutlineStageContent {
  V3KnowledgeOutlineStageContent({
    required this.stage,
    required this.source,
    required this.stateLabel,
    void Function()? onHeadingsParsed,
    void Function()? onPreviewDerived,
  }) : _onHeadingsParsed = onHeadingsParsed,
       _onPreviewDerived = onPreviewDerived;

  final V3KnowledgeOutlineStage stage;
  final String source;
  final String stateLabel;
  final void Function()? _onHeadingsParsed;
  final void Function()? _onPreviewDerived;
  late final String preview = _derivePreview();
  late final List<V3KnowledgeOutlineHeading> headings = _deriveHeadings();

  bool get hasContent => source.trim().isNotEmpty;
  bool get hasHeadings => headings.isNotEmpty;

  Iterable<V3KnowledgeOutlineHeading> get flattenedHeadings sync* {
    for (final heading in headings) {
      yield* heading.flattened;
    }
  }

  List<V3KnowledgeOutlineHeading> _deriveHeadings() {
    _onHeadingsParsed?.call();
    return _parseHeadings(stage, source);
  }

  String _derivePreview() {
    _onPreviewDerived?.call();
    return _preview(source);
  }
}

@immutable
final class V3KnowledgeNoteOutline {
  V3KnowledgeNoteOutline._({
    required this.noteId,
    required this.updatedAt,
    required this.sproutReportId,
    required Map<V3KnowledgeOutlineStage, V3KnowledgeOutlineStageContent>
    stages,
  }) : _stages = Map.unmodifiable(stages);

  factory V3KnowledgeNoteOutline.fromNote(
    V3FeedItem note, {
    @visibleForTesting
    void Function(V3KnowledgeOutlineStage stage)? onHeadingsParsed,
    @visibleForTesting
    void Function(V3KnowledgeOutlineStage stage)? onPreviewDerived,
  }) {
    final sources = <V3KnowledgeOutlineStage, String>{
      V3KnowledgeOutlineStage.raw: note.rawBody,
      V3KnowledgeOutlineStage.summary: note.summaryBody ?? '',
      V3KnowledgeOutlineStage.sprout:
          note.sproutReport?.markdown ?? note.sproutTopic ?? '',
    };
    return V3KnowledgeNoteOutline._(
      noteId: note.id,
      updatedAt: note.updatedAt,
      sproutReportId: note.sproutReport?.id,
      stages: <V3KnowledgeOutlineStage, V3KnowledgeOutlineStageContent>{
        for (final stage in V3KnowledgeOutlineStage.values)
          stage: V3KnowledgeOutlineStageContent(
            stage: stage,
            source: sources[stage]!,
            stateLabel: _stageStateLabel(note, stage, sources[stage]!),
            onHeadingsParsed: () => onHeadingsParsed?.call(stage),
            onPreviewDerived: () => onPreviewDerived?.call(stage),
          ),
      },
    );
  }

  final String noteId;
  final DateTime updatedAt;
  final String? sproutReportId;
  final Map<V3KnowledgeOutlineStage, V3KnowledgeOutlineStageContent> _stages;

  String get cacheKey =>
      '$noteId|${updatedAt.microsecondsSinceEpoch}|${sproutReportId ?? ''}';

  V3KnowledgeOutlineStageContent stage(V3KnowledgeOutlineStage value) =>
      _stages[value]!;
}

List<V3KnowledgeOutlineHeading> _parseHeadings(
  V3KnowledgeOutlineStage stage,
  String source,
) =>
    parseV3MarkdownOutline(source, idPrefix: stage.routeValue, maximumLevel: 6);

String _preview(String source) {
  final normalized = source
      .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'~~~[\s\S]*?~~~'), ' ')
      .replaceAll(RegExp(r'[`*_>#\[\]]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.runes.length <= 88) return normalized;
  return '${String.fromCharCodes(normalized.runes.take(88))}...';
}

String _stageStateLabel(
  V3FeedItem note,
  V3KnowledgeOutlineStage stage,
  String source,
) {
  return switch (stage) {
    V3KnowledgeOutlineStage.raw => source.isEmpty ? '暂无原始内容' : '原始内容',
    V3KnowledgeOutlineStage.summary =>
      source.isNotEmpty
          ? 'AI 纲要'
          : note.summaryError?.trim().isNotEmpty == true
          ? '纲要生成失败'
          : '尚未生成纲要',
    V3KnowledgeOutlineStage.sprout => note.sproutStatus.label,
  };
}
