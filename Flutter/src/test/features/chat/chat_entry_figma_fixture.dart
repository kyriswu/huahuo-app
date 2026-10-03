import 'package:flutter/material.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_figma_spec.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_surface.dart';

import '../../support/figma_golden_test_support.dart';

Future<void> loadChatEntryFigmaFonts() => loadFigmaGoldenFonts();

Widget chatEntryFigmaFixture({
  ValueChanged<ChatEntrySuggestionSpec>? onSuggestion,
  VoidCallback? onHistory,
  VoidCallback? onNewConversation,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: figmaGoldenTheme(),
    home: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '聊一聊',
                        style: TextStyle(
                          fontSize: 18,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    ChatEntryHeaderActions(
                      onHistory: onHistory ?? () {},
                      onNewConversation: onNewConversation ?? () {},
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: ChatEntrySurface(onSuggestion: onSuggestion ?? (_) {}),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
