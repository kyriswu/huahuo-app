import 'package:flutter/material.dart';

enum ChatEntrySuggestionKind { prompt, notePicker }

@immutable
final class ChatEntrySuggestionSpec {
  const ChatEntrySuggestionSpec({required this.kind, required this.label});

  const ChatEntrySuggestionSpec.question(this.label)
    : kind = ChatEntrySuggestionKind.prompt;

  const ChatEntrySuggestionSpec.assetReference(this.label)
    : kind = ChatEntrySuggestionKind.notePicker;

  final ChatEntrySuggestionKind kind;
  final String label;
}

abstract final class ChatEntryFigmaSpec {
  static const sourceNodeId = '2084:22831';
  static const enabled = bool.fromEnvironment(
    'HU_AH_UO_M05_CHAT_ENTRY',
    defaultValue: true,
  );

  static const greeting = 'Hello，我是花火 AI';
  static const supportingCopy = '把你的想法整理成清晰、可执行的创作方向。';
  static const sectionTitle = '猜你想问';
  static const refreshLabel = '换一批';
  static const composerHint = '输入你的问题或想法…';
  static const disclaimer = '内容由 AI 生成，仅供参考';

  static const accent = Color(0xFF94632E);
  static const suggestionSurface = Color(0xFFF6F5F3);

  static const startupSuggestionSets = <List<ChatEntrySuggestionSpec>>[
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.notePicker,
        label: '引用一份资产，帮我找到可继续创作的方向',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '一个模糊想法，怎样变成清晰的创作主题？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '短视频开头怎样写，观众才愿意继续看？',
      ),
    ],
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.notePicker,
        label: '引用一份资产，帮我把核心观点变成内容提纲',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '没有明确选题时，可以从哪些问题找方向？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '一篇有观点的短文，可以使用什么结构？',
      ),
    ],
  ];

  static const suggestionSets = <List<ChatEntrySuggestionSpec>>[
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.notePicker,
        label: '引用一份资产，帮我找到可继续创作的方向',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '一个模糊想法，怎样变成清晰的创作主题？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '短视频开头怎样写，观众才愿意继续看？',
      ),
    ],
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.notePicker,
        label: '引用一份资产，帮我把核心观点变成内容提纲',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '没有明确选题时，可以从哪些问题找方向？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '一篇有观点的短文，可以使用什么结构？',
      ),
    ],
  ];

  static const noteSuggestionSets = <List<ChatEntrySuggestionSpec>>[
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '这条笔记的核心判断是什么？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '怎样把信息整理成可调用的知识？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '如何让这条笔记进入下一步行动？',
      ),
    ],
    <ChatEntrySuggestionSpec>[
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '这条笔记里最值得继续追问的是什么？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '哪些内容可以沉淀成可复用的方法？',
      ),
      ChatEntrySuggestionSpec(
        kind: ChatEntrySuggestionKind.prompt,
        label: '基于这条笔记，下一步最适合做什么？',
      ),
    ],
  ];
}
