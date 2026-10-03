import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/chat/application/chat_stream_reveal_buffer.dart';

void main() {
  test('disabled coalescing reveals each target immediately', () async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      coalesceUpdates: false,
      onReveal: revealed.add,
    );
    addTearDown(buffer.dispose);

    buffer.ingest('第一段');
    buffer.ingest('第二段');

    expect(buffer.visibleText, '第一段第二段');
    expect(revealed, <String>['第一段', '第一段第二段']);
    await Future<void>.delayed(Duration.zero);
    expect(revealed, hasLength(2));
  });

  test('reveals Unicode grapheme clusters without splitting them', () async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(milliseconds: 1),
      moderateDelay: const Duration(milliseconds: 1),
      catchUpDelay: const Duration(milliseconds: 1),
    );
    addTearDown(buffer.dispose);
    const source = 'e\u0301👨‍👩‍👧‍👦好';

    buffer.ingest(source, replace: true);
    await Future<void>.delayed(const Duration(milliseconds: 24));

    expect(revealed.first, 'e\u0301');
    expect(revealed, contains('e\u0301👨‍👩‍👧‍👦'));
    expect(buffer.visibleText, source);
    expect(buffer.visibleText.characters.length, 3);
  });

  test('preserves whitespace and applies replacement targets', () async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(milliseconds: 1),
      moderateDelay: const Duration(milliseconds: 1),
      catchUpDelay: const Duration(milliseconds: 1),
    );
    addTearDown(buffer.dispose);

    buffer.ingest('第一段', replace: true);
    await Future<void>.delayed(const Duration(milliseconds: 24));
    buffer.ingest('\n  第二段');
    await Future<void>.delayed(const Duration(milliseconds: 24));
    expect(buffer.visibleText, '第一段\n  第二段');

    buffer.ingest('第一段\n  已修订', replace: true);
    expect(revealed.last, '第一段\n  ');
    await Future<void>.delayed(const Duration(milliseconds: 24));
    expect(buffer.visibleText, '第一段\n  已修订');
  });

  test('a completely revised target never publishes an empty frame', () async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(milliseconds: 1),
      moderateDelay: const Duration(milliseconds: 1),
      catchUpDelay: const Duration(milliseconds: 1),
    );
    addTearDown(buffer.dispose);

    buffer.ingest('旧的完整回答', replace: true);
    await Future<void>.delayed(const Duration(milliseconds: 24));
    final replacementStart = revealed.length;

    buffer.ingest('全新且不同的正式回答', replace: true);

    expect(revealed.skip(replacementStart), isNot(contains('')));
    expect(revealed.last, startsWith('全'));
    await Future<void>.delayed(const Duration(milliseconds: 24));
    expect(buffer.visibleText, '全新且不同的正式回答');
  });

  test('resegments a grapheme cluster that spans transport chunks', () async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(milliseconds: 1),
      moderateDelay: const Duration(milliseconds: 1),
      catchUpDelay: const Duration(milliseconds: 1),
    );
    addTearDown(buffer.dispose);

    buffer.ingest('e', replace: true);
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(buffer.visibleText, 'e');

    buffer.ingest('\u0301');

    expect(buffer.targetText, 'e\u0301');
    expect(buffer.visibleText, 'e\u0301');
    expect(buffer.visibleText.characters.length, 1);
    expect(revealed.last, 'e\u0301');
  });

  test('flushes a queued target synchronously', () {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(days: 1),
      moderateDelay: const Duration(days: 1),
      catchUpDelay: const Duration(days: 1),
    );
    addTearDown(buffer.dispose);

    buffer.ingest('尚未展示完的回复', replace: true);
    buffer.flush();

    expect(buffer.pendingGraphemeCount, 0);
    expect(buffer.visibleText, '尚未展示完的回复');
    expect(revealed.last, '尚未展示完的回复');
  });

  test(
    'accelerates a large queued draft before normal cadence resumes',
    () async {
      final revealed = <String>[];
      final buffer = ChatStreamRevealBuffer(
        onReveal: revealed.add,
        normalDelay: const Duration(days: 1),
        moderateDelay: const Duration(days: 1),
        catchUpDelay: Duration.zero,
      );
      addTearDown(buffer.dispose);
      final source = List<String>.filled(160, '人').join();

      buffer.ingest(source, replace: true);
      await Future<void>.delayed(Duration.zero);

      expect(revealed, isNotEmpty);
      expect(revealed.last.characters.length, greaterThan(1));
      expect(buffer.pendingGraphemeCount, lessThan(159));
    },
  );

  testWidgets('continuous transport chunks do not postpone the first reveal', (
    tester,
  ) async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(
      onReveal: revealed.add,
      normalDelay: const Duration(milliseconds: 50),
      moderateDelay: const Duration(milliseconds: 50),
      catchUpDelay: const Duration(milliseconds: 50),
    );
    addTearDown(buffer.dispose);

    buffer.ingest('第');
    for (final chunk in <String>['一', '段', '连', '续']) {
      await tester.pump(const Duration(milliseconds: 10));
      buffer.ingest(chunk);
    }
    expect(revealed, isEmpty);

    await tester.pump(const Duration(milliseconds: 10));

    expect(revealed, isNotEmpty);
    expect(revealed.first, '第');
    buffer.dispose();
  });

  testWidgets('caps a large draft at about 30 updates per second', (
    tester,
  ) async {
    final revealed = <String>[];
    final buffer = ChatStreamRevealBuffer(onReveal: revealed.add);
    addTearDown(buffer.dispose);
    final source = List<String>.filled(1000, '人').join();

    buffer.ingest(source, replace: true);
    await tester.pump(const Duration(seconds: 1));

    expect(revealed, isNotEmpty);
    expect(revealed.length, lessThanOrEqualTo(31));
    expect(buffer.pendingGraphemeCount, greaterThan(0));

    buffer.flush();
    final callsAfterFlush = revealed.length;
    expect(buffer.visibleText, source);
    expect(buffer.pendingGraphemeCount, 0);

    await tester.pump(const Duration(seconds: 1));
    expect(revealed.length, callsAfterFlush);
  });
}
