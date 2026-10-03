import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_figma_spec.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_surface.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_onboarding_spotlight.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('root safe area and keyboard bound a locally padded spotlight', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final viewport in [
      (
        size: const Size(320, 568),
        padding: const EdgeInsets.only(top: 48, bottom: 34),
        keyboard: 0.0,
      ),
      (
        size: const Size(320, 568),
        padding: const EdgeInsets.only(top: 48, bottom: 34),
        keyboard: 240.0,
      ),
      (
        size: const Size(852, 393),
        padding: const EdgeInsets.only(left: 59, right: 59, bottom: 21),
        keyboard: 0.0,
      ),
    ]) {
      await tester.binding.setSurfaceSize(viewport.size);
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(viewport),
          theme: figmaGoldenTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: viewport.padding,
              viewInsets: EdgeInsets.only(bottom: viewport.keyboard),
              textScaler: const TextScaler.linear(1.8),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              child: Align(
                alignment: viewport.size.width > viewport.size.height
                    ? Alignment.bottomLeft
                    : Alignment.center,
                child: V3OnboardingSpotlight(
                  visible: true,
                  step: 2,
                  title: '选一个问题，开始第一次创作',
                  message: '点这条「猜你想问」，就会发送给花火并收到回复。之后也可以直接说出需求，让它帮你继续创作、调整或润色。',
                  onSkip: () {},
                  child: const SizedBox(width: 160, height: 48),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.descendant(
        of: find.byKey(const ValueKey('startup-chat-spotlight-2')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.canvas,
        ),
      );
      expect(card, findsOneWidget);
      final rect = tester.getRect(card);
      expect(rect.top, greaterThanOrEqualTo(viewport.padding.top));
      expect(rect.left, greaterThanOrEqualTo(viewport.padding.left));
      expect(
        rect.right,
        lessThanOrEqualTo(viewport.size.width - viewport.padding.right),
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(
          viewport.size.height -
              (viewport.keyboard > viewport.padding.bottom
                  ? viewport.keyboard
                  : viewport.padding.bottom),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('real target stays accessible and background taps are blocked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    var opened = 0;
    var background = 0;
    var visible = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 30,
                  right: 20,
                  child: TextButton(
                    onPressed: () => background++,
                    child: const Text('背景操作'),
                  ),
                ),
                Positioned(
                  left: 24,
                  bottom: 44,
                  child: V3OnboardingSpotlight(
                    visible: visible,
                    step: 1,
                    title: '点这里，和花火聊一聊',
                    message: '这个花火图标就是「聊一聊」入口。想选题、写文案或脚本、润色修改内容，都可以从这里开始。',
                    onSkip: () => setState(() => visible = false),
                    child: V3ChatEntry(onTap: () => opened++),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('背景操作')));
    expect(background, 0);
    await tester.tap(find.byType(V3ChatEntry));
    expect(opened, 1);
    await tester.tap(find.byKey(const ValueKey('startup-chat-guide-skip')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('startup-chat-spotlight-1')),
      findsNothing,
    );
    await tester.tap(find.text('背景操作'));
    expect(background, 1);
    semantics.dispose();
  });

  testWidgets('random real suggestion only sends on an explicit tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final submitted = <ChatEntrySuggestionSpec>[];
    var visible = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            appBar: AppBar(title: const Text('聊一聊')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ChatEntrySurface(
                showStartupGuide: visible,
                suggestionSets: ChatEntryFigmaSpec.startupSuggestionSets,
                onSkipStartupGuide: () => setState(() => visible = false),
                onSuggestion: (suggestion) {
                  submitted.add(suggestion);
                  setState(() => visible = false);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(submitted, isEmpty);
    final target = find.byWidgetPredicate(
      (widget) => widget is V3OnboardingSpotlight && widget.visible,
    );
    expect(target, findsOneWidget);
    final label = tester
        .widget<Text>(
          find.descendant(of: target, matching: find.byType(Text)).first,
        )
        .data!;
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(submitted, hasLength(1));
    expect(submitted.single.kind, ChatEntrySuggestionKind.prompt);
    expect(submitted.single.label, label);
    expect(
      find.byKey(const ValueKey('startup-chat-spotlight-2')),
      findsNothing,
    );
  });

  testWidgets('covered routes hide the spotlight and return restores it', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Center(
            child: V3OnboardingSpotlight(
              visible: true,
              step: 1,
              title: '引导',
              message: '说明',
              onSkip: () {},
              child: const SizedBox(width: 50, height: 50),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('引导'), findsOneWidget);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('其他页面')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('引导'), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('引导'), findsOneWidget);
  });

  testWidgets('small screen large text and keyboard keep skip reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var skipped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.8),
            viewInsets: const EdgeInsets.only(bottom: 200),
          ),
          child: child!,
        ),
        home: Scaffold(
          resizeToAvoidBottomInset: true,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: V3OnboardingSpotlight(
              visible: true,
              step: 2,
              title: '选一个问题，开始第一次创作',
              message: '点这条「猜你想问」，就会发送给花火并收到回复。之后也可以直接说出需求，让它帮你继续创作、调整或润色。',
              onSkip: () => skipped = true,
              child: const SizedBox(width: 200, height: 44),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final skip = find.byKey(const ValueKey('startup-chat-guide-skip'));
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    expect(skipped, isTrue);
  });
}
