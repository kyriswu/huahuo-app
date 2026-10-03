import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_controller.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_generation_controller.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_providers.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/features/book_work/masterpiece_test_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const label = String.fromEnvironment(
    'MASTERPIECE_AUDIT_LABEL',
    defaultValue: 'current',
  );
  for (final count in [99, 100]) {
    testWidgets('representative work $count-note page and information menu', (
      tester,
    ) async {
      final generation = MasterpieceGenerationController(
        remote: _EligibilityRemote(count),
        store: _GenerationStore(),
        identity: 'visual-only-workspace',
      );
      final runtime = MasterpieceController(
        remote: TestMasterpieceRemote(),
        store: TestMasterpieceStore(),
        generation: generation,
      );
      await runtime.refresh();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            masterpieceControllerProvider.overrideWith((ref) => runtime),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HuahuoV3Theme.light(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const Scaffold(
              body: SafeArea(child: V3MasterpiecePage(active: false)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('masterpiece-more')));
      await tester.pumpAndSettle();
      await _capture(binding, '${label}_${count}_menu');
      expect(tester.takeException(), isNull);
      expect(find.text('代表作信息'), findsOneWidget);
      final close = find.byTooltip('关闭');
      await tester.tap(close.evaluate().isNotEmpty ? close : find.text('关闭'));
      await tester.pumpAndSettle();
        expect(find.text('代表作信息'), findsNothing);
        await _capture(binding, '${label}_${count}_page');
      if (count == 100) {
        await tester.tap(find.byKey(const ValueKey('masterpiece-more')));
        await tester.pumpAndSettle();
        final generate = find.byKey(
          const ValueKey('masterpiece-information-generate'),
        );
        await tester.ensureVisible(generate);
        await tester.tap(generate);
        await tester.pumpAndSettle();
        await _capture(binding, '${label}_${count}_confirmation');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(generation.intent, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final bytes = await binding.takeScreenshot(name);
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/MasterpieceVisualAudit');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes);
  debugPrint('MASTERPIECE_VISUAL_CAPTURE $name');
}

final class _GenerationStore implements MasterpieceGenerationStore {
  MasterpieceGenerationRecord? value;
  @override
  MasterpieceGenerationRecord? read() => value;
  @override
  Future<void> write(MasterpieceGenerationRecord record) async =>
      value = record;
}

final class _EligibilityRemote implements MasterpieceGenerationRemote {
  _EligibilityRemote(this.count);
  final int count;
  @override
  Future<MasterpieceEligibility> eligibility() async => MasterpieceEligibility([
    for (var index = 0; index < count; index++)
      MasterpieceSourceHead('note-$index', 'revision-$index'),
  ]);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected remote write: ${invocation.memberName}');
}
