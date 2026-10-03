import 'package:flutter/foundation.dart';

import 'markdown_preview_preferences.dart';

/// The trusted document layouts bundled with the desktop editor.
///
/// A layout is intentionally not a CSS skin. It controls the hierarchy and
/// placement of safe Markdown blocks rendered by the native or static HTML
/// previewer.
enum MarkdownPresentationLayout {
  article,
  parchment,
  magazine,
  focus,
  research,
  brief,
}

/// Metadata for an app-shipped Markdown presentation template.
///
/// [id] is the stable identifier exposed to assistant integrations. Calling a
/// template can only select one of these constrained layouts. It never grants
/// an integration a way to inject arbitrary HTML, CSS, JavaScript, or fonts.
@immutable
final class MarkdownPresentationTemplate {
  const MarkdownPresentationTemplate({
    required this.id,
    required this.theme,
    required this.layout,
    required this.label,
    required this.description,
    required this.agentGuidance,
  });

  final String id;
  final MarkdownPreviewTheme theme;
  final MarkdownPresentationLayout layout;
  final String label;
  final String description;

  /// A short, bounded instruction for an assistant choosing a document view.
  final String agentGuidance;
}

/// Closed registry for built-in Markdown presentation templates.
///
/// It follows the useful part of HTML Anything's template model: a stable
/// template ID represents a distinct content composition, not a palette.
/// Unlike its arbitrary-HTML path, every composition here is implemented by
/// reviewed Flutter or static, script-disabled HTML code.
abstract final class MarkdownPresentationTemplateRegistry {
  static const MarkdownPresentationTemplate readerQuiet =
      MarkdownPresentationTemplate(
        id: 'reader-quiet',
        theme: MarkdownPreviewTheme.quiet,
        layout: MarkdownPresentationLayout.article,
        label: '安静阅读',
        description: '清晰正文与适度目录，适合日常长文。',
        agentGuidance:
            'Use for neutral long-form reading with a calm article hierarchy.',
      );

  static const MarkdownPresentationTemplate
  docKamiParchment = MarkdownPresentationTemplate(
    id: 'doc-kami-parchment',
    theme: MarkdownPreviewTheme.paper,
    layout: MarkdownPresentationLayout.parchment,
    label: '纸页文档',
    description: '独立纸面、页首页尾与收束版心，适合正式文稿。',
    agentGuidance:
        'Use for document-like reading where a page boundary improves focus.',
  );

  static const MarkdownPresentationTemplate
  articleMagazine = MarkdownPresentationTemplate(
    id: 'article-magazine',
    theme: MarkdownPreviewTheme.editorial,
    layout: MarkdownPresentationLayout.magazine,
    label: '杂志特写',
    description: '标题、导语与内容轨分层，适合专题和叙事内容。',
    agentGuidance:
        'Use for a featured article with a strong title, deck, and editorial reading rhythm.',
  );

  static const MarkdownPresentationTemplate readerFocus =
      MarkdownPresentationTemplate(
        id: 'reader-focus',
        theme: MarkdownPreviewTheme.focus,
        layout: MarkdownPresentationLayout.focus,
        label: '沉浸专注',
        description: '窄版心、舒展行距，适合连续阅读与校对。',
        agentGuidance:
            'Use for uninterrupted close reading of prose or a draft.',
      );

  static const MarkdownPresentationTemplate
  researchOutline = MarkdownPresentationTemplate(
    id: 'research-outline',
    theme: MarkdownPreviewTheme.research,
    layout: MarkdownPresentationLayout.research,
    label: '研读提纲',
    description: '固定结构提纲与正文并列，适合资料、论文和知识梳理。',
    agentGuidance:
        'Use when headings and citations should remain visible beside the source text.',
  );

  static const MarkdownPresentationTemplate
  briefExecutive = MarkdownPresentationTemplate(
    id: 'brief-executive',
    theme: MarkdownPreviewTheme.brief,
    layout: MarkdownPresentationLayout.brief,
    label: '执行简报',
    description: '先摘要后细节，强调行动信息和紧凑结构。',
    agentGuidance:
        'Use for plans, reports, and decision notes that need a concise opening summary.',
  );

  static const List<MarkdownPresentationTemplate> templates =
      <MarkdownPresentationTemplate>[
        readerQuiet,
        docKamiParchment,
        articleMagazine,
        readerFocus,
        researchOutline,
        briefExecutive,
      ];

  static MarkdownPresentationTemplate forTheme(MarkdownPreviewTheme theme) {
    for (final template in templates) {
      if (template.theme == theme) return template;
    }
    return readerQuiet;
  }

  static MarkdownPresentationTemplate? tryResolve(String? id) {
    if (id == null) return null;
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }

  static MarkdownPreviewTheme? themeForId(String? id) => tryResolve(id)?.theme;
}

extension MarkdownPreviewThemePresentationTemplate on MarkdownPreviewTheme {
  MarkdownPresentationTemplate get presentationTemplate =>
      MarkdownPresentationTemplateRegistry.forTheme(this);
}
