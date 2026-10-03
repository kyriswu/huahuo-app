import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_figma_spec.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_surface.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'chat_entry_figma_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M05 entry renders the exact first suggestion set', (
    tester,
  ) async {
    _expectBalancedSuggestions(ChatEntryFigmaSpec.suggestionSets);
    _expectBalancedSuggestions(ChatEntryFigmaSpec.startupSuggestionSets);
    await tester.pumpWidget(chatEntryFigmaFixture());

    expect(find.text(ChatEntryFigmaSpec.greeting), findsOneWidget);
    expect(find.text(ChatEntryFigmaSpec.supportingCopy), findsOneWidget);
    expect(find.text(ChatEntryFigmaSpec.sectionTitle), findsOneWidget);
    for (final suggestion in ChatEntryFigmaSpec.suggestionSets.first) {
      expect(find.text(suggestion.label), findsOneWidget);
    }

    final firstTile = find.byKey(
      const ValueKey<String>('chat-entry-suggestion-notePicker'),
    );
    expect(tester.getSize(firstTile).height, 54);
    expect(
      tester
          .widget<Text>(find.text(ChatEntryFigmaSpec.greeting))
          .style
          ?.fontSize,
      16,
    );
    expect(
      tester
          .widget<Text>(find.text(ChatEntryFigmaSpec.supportingCopy))
          .style
          ?.fontSize,
      13,
    );
    expect(
      tester
          .widget<Text>(find.text(ChatEntryFigmaSpec.sectionTitle))
          .style
          ?.fontSize,
      18,
    );
    expect(
      tester
          .widget<Text>(
            find.text(ChatEntryFigmaSpec.suggestionSets.first.first.label),
          )
          .style
          ?.fontSize,
      15,
    );
  });

  testWidgets('M05 suggestion actions stay typed and rotate locally', (
    tester,
  ) async {
    ChatEntrySuggestionSpec? selected;
    await tester.pumpWidget(
      chatEntryFigmaFixture(onSuggestion: (value) => selected = value),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
    );
    expect(selected?.kind, ChatEntrySuggestionKind.notePicker);
    expect(
      selected?.label,
      ChatEntryFigmaSpec.suggestionSets.first.first.label,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
    );
    await tester.pump();
    expect(
      find.text(ChatEntryFigmaSpec.suggestionSets.first.first.label),
      findsNothing,
    );
    expect(
      find.text(ChatEntryFigmaSpec.suggestionSets[1].first.label),
      findsOneWidget,
    );
  });

  testWidgets('M05 header actions expose the existing chat commands', (
    tester,
  ) async {
    var historyCalls = 0;
    var newConversationCalls = 0;
    await tester.pumpWidget(
      chatEntryFigmaFixture(
        onHistory: () => historyCalls += 1,
        onNewConversation: () => newConversationCalls += 1,
      ),
    );

    final actions = find.byType(ChatEntryHeaderActions);
    expect(tester.getSize(find.byTooltip('会话列表')).height, 40);
    expect(tester.getSize(find.byTooltip('新建会话')).height, 40);
    expect(tester.getSize(actions), const Size(82, 40));
    expect(find.byIcon(LucideIcons.history), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('新建会话')).dx,
      lessThan(tester.getCenter(find.byTooltip('会话列表')).dx),
    );

    await tester.tap(find.byTooltip('会话列表'));
    await tester.tap(find.byTooltip('新建会话'));
    expect(historyCalls, 1);
    expect(newConversationCalls, 1);
  });
}

void _expectBalancedSuggestions(
  List<List<ChatEntrySuggestionSpec>> suggestionSets,
) {
  expect(suggestionSets.length, greaterThanOrEqualTo(2));
  for (final suggestions in suggestionSets) {
    expect(suggestions, hasLength(3));
    expect(suggestions.first.kind, ChatEntrySuggestionKind.notePicker);
    expect(
      suggestions.skip(1).map((suggestion) => suggestion.kind),
      everyElement(ChatEntrySuggestionKind.prompt),
    );
    expect(
      suggestions.where(
        (suggestion) => suggestion.kind == ChatEntrySuggestionKind.notePicker,
      ),
      hasLength(1),
    );
    expect(
      suggestions.where(
        (suggestion) => suggestion.kind == ChatEntrySuggestionKind.prompt,
      ),
      hasLength(2),
    );
  }
}
