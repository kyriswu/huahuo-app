import 'package:flutter/material.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/note/note_detail_surface.dart';

import '../../support/figma_golden_test_support.dart';

Widget noteDetailFigmaFixture({
  bool readOnly = false,
  VoidCallback? onBack,
  VoidCallback? onMore,
  VoidCallback? onChat,
  VoidCallback? onAssistant,
  VoidCallback? onFreeCreation,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: figmaGoldenTheme(),
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(402, 874),
        padding: EdgeInsets.only(top: 54, bottom: 24),
        viewPadding: EdgeInsets.only(top: 54, bottom: 24),
      ),
      child: _NoteDetailFigmaFixture(
        readOnly: readOnly,
        onBack: onBack ?? () {},
        onMore: onMore ?? () {},
        onChat: onChat ?? () {},
        onAssistant: onAssistant ?? () {},
        onFreeCreation: onFreeCreation ?? () {},
      ),
    ),
  );
}

class _NoteDetailFigmaFixture extends StatefulWidget {
  const _NoteDetailFigmaFixture({
    required this.readOnly,
    required this.onBack,
    required this.onMore,
    required this.onChat,
    required this.onAssistant,
    required this.onFreeCreation,
  });

  final bool readOnly;
  final VoidCallback onBack;
  final VoidCallback onMore;
  final VoidCallback onChat;
  final VoidCallback onAssistant;
  final VoidCallback onFreeCreation;

  @override
  State<_NoteDetailFigmaFixture> createState() =>
      _NoteDetailFigmaFixtureState();
}

class _NoteDetailFigmaFixtureState extends State<_NoteDetailFigmaFixture> {
  late final PageController _pageController;
  V3ContentStage _stage = V3ContentStage.raw;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectStage(V3ContentStage stage) {
    setState(() => _stage = stage);
    _pageController.animateToPage(
      stage.index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NoteDetailSurface(
      title: '内容不是堆数量，而是形成判断',
      subtitle: '笔记 · 8月19日 · 知识',
      stage: _stage,
      onBack: widget.onBack,
      onMore: widget.onMore,
      onSelectStage: _selectStage,
      pageController: _pageController,
      onPageChanged: (index) {
        final stage = V3ContentStage.values[index];
        if (stage != _stage) setState(() => _stage = stage);
      },
      pages: const [
        _FixturePage(
          key: ValueKey<String>('fixture-raw-page'),
          body:
              '内容不是靠堆砌数量产生价值，而是通过整理、比较和提炼，'
              '形成自己的判断。\n\n'
              '这条笔记保留原始上下文，纲要和深度洞察会基于此内容继续生成。',
        ),
        _FixturePage(
          key: ValueKey<String>('fixture-summary-page'),
          body: '纲要\n\n- 更新流程与版本引导\n- 创作入口的使用反馈',
        ),
        _FixturePage(
          key: ValueKey<String>('fixture-sprout-page'),
          body: '深度洞察\n\n从用户的中断体验出发，梳理更清晰的创作引导。',
        ),
      ],
      bottomBar: NoteDetailCreationDock(
        readOnly: widget.readOnly,
        onChat: widget.onChat,
        onAssistant: widget.onAssistant,
        onFreeCreation: widget.onFreeCreation,
      ),
    );
  }
}

class _FixturePage extends StatelessWidget {
  const _FixturePage({required this.body, super.key});

  final String body;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Text(
        body,
        style: const TextStyle(
          fontSize: 15,
          height: 1.6,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
