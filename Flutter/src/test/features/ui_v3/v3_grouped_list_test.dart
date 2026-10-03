import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

void main() {
  testWidgets('disclosure uses one right-to-down motion contract', (
    tester,
  ) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: V3DisclosureTile(
              title: const Text('详情'),
              onExpansionChanged: (value) => expanded = value,
              children: const [Text('展开内容')],
            ),
          ),
        ),
      ),
    );

    AnimatedRotation rotation() =>
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));
    ExpansionTile tile() =>
        tester.widget<ExpansionTile>(find.byType(ExpansionTile));

    expect(rotation().turns, 0);
    expect(rotation().duration, Duration.zero);
    expect(tile().expansionAnimationStyle?.duration, Duration.zero);
    expect(tile().expansionAnimationStyle?.reverseDuration, Duration.zero);
    expect(tile().expansionAnimationStyle?.curve, Curves.easeOutCubic);
    expect(find.text('展开内容'), findsNothing);

    await tester.tap(find.text('详情'));
    await tester.pump();

    expect(expanded, isTrue);
    expect(rotation().turns, .25);
    expect(find.text('展开内容'), findsOneWidget);
  });

  testWidgets('grouped list uses one surface and independent row actions', (
    tester,
  ) async {
    var firstTaps = 0;
    var secondTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3GroupedList(
            children: [
              V3GroupedListTile(
                key: const ValueKey<String>('group-row-first'),
                leading: const Icon(Icons.looks_one_outlined),
                title: const Text('第一项'),
                onTap: () => firstTaps++,
              ),
              V3GroupedListTile(
                key: const ValueKey<String>('group-row-second'),
                leading: const Icon(Icons.looks_two_outlined),
                title: const Text('第二项'),
                onTap: () => secondTaps++,
              ),
              const V3GroupedListTile(
                key: ValueKey<String>('group-row-disabled'),
                leading: Icon(Icons.block_outlined),
                title: Text('不可用'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(V3Card), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('v3-grouped-list-divider-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('v3-grouped-list-divider-2')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('group-row-first')))
          .height,
      greaterThanOrEqualTo(44),
    );

    await tester.tap(find.byKey(const ValueKey<String>('group-row-first')));
    await tester.tap(find.byKey(const ValueKey<String>('group-row-second')));
    await tester.tap(find.byKey(const ValueKey<String>('group-row-disabled')));
    expect(firstTaps, 1);
    expect(secondTaps, 1);
  });
}
