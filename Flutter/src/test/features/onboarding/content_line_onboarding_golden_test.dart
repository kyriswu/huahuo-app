import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';

import '../../support/figma_golden_test_support.dart';

import 'content_line_onboarding_test_support.dart';

// Keep font-rendering fixtures isolated from behavioral widget tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M10 business questionnaire covers every curated visual state', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    final fixture = await createOnboardingPageFixture();
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(onboardingPageTestApp(router, fixture));
    await tester.pump();

    await _golden(tester, 'onboarding_default.png');
    fixture.controller.selectMode(OnboardingIntakeMode.business);
    fixture.controller.updateAnswer('customerScope', '本地客户');
    await tester.pump();
    await _golden(tester, 'onboarding_business_1.png');

    fixture.controller.goNext();
    fixture.controller.updateAnswer(
      'productDescription',
      '为中小企业提供视频内容策划与落地服务。',
    );
    await tester.pump();
    await _golden(tester, 'onboarding_business_2.png');

    fixture.controller.goNext();
    fixture.controller.updateAnswer('desiredCustomer', '有持续内容需求的本地品牌负责人。');
    await tester.pump();
    await _golden(tester, 'onboarding_business_3.png');

    fixture.controller.goNext();
    fixture.controller.updateAnswer('customerTalkValue', <String>[
      '行业信息差',
      '有自己的观点',
    ]);
    await tester.pump();
    await _golden(tester, 'onboarding_business_4.png');
  });

  testWidgets(
    'M10 no-business questionnaire covers every curated visual state',
    (tester) async {
      _installGoldenViewport(tester);
      final fixture = await createOnboardingPageFixture();
      final router = onboardingPageTestRouter();
      addTearDown(router.dispose);
      addTearDown(fixture.dispose);
      await tester.pumpWidget(onboardingPageTestApp(router, fixture));
      await tester.pump();

      fixture.controller.selectMode(OnboardingIntakeMode.noBusiness);
      const answers = <String, String>{
        'userProfile': '想服务需要表达个人观点的职场新人。',
        'direction': '想做职场成长和表达效率方向。',
        'strengths': '擅长把复杂经验整理成可执行的表达。',
        'dailyConcerns': '关心工作方法、阅读和个人成长。',
        'readingHabit': '最近读了《思考，快与慢》，关注决策。',
        'workHistory': '做过产品运营和内容策划。',
        'schoolMajor': '新闻传播学。',
      };
      final goldenNames = <String>[
        for (var step = 1; step <= answers.length; step += 1)
          'onboarding_no_business_$step.png',
      ];
      var index = 0;
      for (final entry in answers.entries) {
        fixture.controller.updateAnswer(entry.key, entry.value);
        await tester.pump();
        await _golden(tester, goldenNames[index]);
        if (index < answers.length - 1) fixture.controller.goNext();
        index += 1;
      }
    },
  );
}

void _installGoldenViewport(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _golden(WidgetTester tester, String fileName) async {
  // Capture a settled visual state, including Material button transitions.
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$fileName'),
  );
}
