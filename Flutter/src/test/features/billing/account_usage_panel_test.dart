import 'package:huahuoai_app/features/billing/data/account_usage_repository.dart';
import 'package:huahuoai_app/app/di/account_usage_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/billing/application/account_usage_controller.dart';
import 'package:huahuoai_app/features/billing/domain/account_usage_repository.dart';
import 'package:huahuoai_app/features/billing/widgets/account_usage_panel.dart';
import 'package:huahuoai_app/features/ui_v3/application/user_profile_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_account_profile_page.dart';

void main() {
  testWidgets(
    'usage shows credits cloud and settled transcription with working details',
    (tester) async {
      final port = _UsagePort();
      final controller = AccountUsageController(repository: port);
      addTearDown(controller.dispose);
      await controller.load();
      await _pumpPanel(tester, controller);
      expect(find.text('9,500 点'), findsOneWidget);
      expect(find.text('1 GiB / 4 GiB'), findsOneWidget);
      expect(find.text('25.0%'), findsOneWidget);
      expect(find.text('1 小时 1 分 1.50 秒'), findsOneWidget);
      await tester.ensureVisible(find.text('空间明细'));
      await tester.tap(find.text('空间明细'));
      await tester.pumpAndSettle();
      expect(find.text('保留的历史版本'), findsOneWidget);
      expect(find.text('不设数量上限'), findsOneWidget);
      await tester.ensureVisible(find.text('查看生成次数与 Token 计量'));
      await tester.tap(find.text('查看生成次数与 Token 计量'));
      await tester.pumpAndSettle();
      expect(find.text('服务生成次数'), findsOneWidget);
      expect(find.text('已用 3 次'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('account-usage-refresh')),
      );
      await tester.tap(find.byKey(const ValueKey('account-usage-refresh')));
      await tester.pumpAndSettle();
      expect(port.reads, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unavailable values do not render invented zeros or capacities', (
    tester,
  ) async {
    final controller = AccountUsageController(
      repository: const UnavailableAccountUsageRepository(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await _pumpPanel(tester, controller);
    expect(find.textContaining('转写用量暂不可用'), findsOneWidget);
    expect(find.textContaining('云空间暂不可用'), findsOneWidget);
    expect(find.text('0 秒'), findsNothing);
    expect(find.textContaining('30 GiB'), findsNothing);
  });

  testWidgets(
    'narrow large-text layout preserves actual over-capacity percentage',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AccountUsageController(
        repository: _UsagePort(overCapacity: true),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await _pumpPanel(tester, controller, textScale: 1.8);
      expect(find.text('125.0%'), findsOneWidget);
      expect(find.textContaining('云空间已超出容量'), findsOneWidget);
      await tester.ensureVisible(find.text('转写明细'));
      await tester.tap(find.text('转写明细'));
      await tester.pumpAndSettle();
      expect(find.textContaining('UTC'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account placement and refresh pause on hidden routes and background',
    (tester) async {
      final port = _UsagePort();
      final container = ProviderContainer(
        overrides: [
          accountUsageRepositoryProvider.overrideWithValue(port),
          voiceprintControllerProvider.overrideWith(
            (ref) => VoiceprintController(
              recorder: const UnavailableVoiceRecorderPort(),
              port: SessionMockVoiceprintPort(
                deleteLocalSample: (_) async => true,
              ),
              initialUserId: null,
            ),
          ),
          userProfilePortProvider.overrideWith(
            (ref) => SessionMockUserProfilePort(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final activity = container.read(appActivityCoordinatorProvider);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorObservers: [appRouteObserver],
            home: const V3AccountProfilePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(port.reads, 1);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('account-usage-panel'))).dy,
        greaterThan(tester.getBottomLeft(find.text('无限花火会员')).dy),
      );
      final navigator = Navigator.of(
        tester.element(find.byType(V3AccountProfilePage)),
      );
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('another page')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 40));
      expect(port.reads, 1);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(port.reads, 2);
      activity.updateLifecycle(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 40));
      expect(port.reads, 2);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(port.reads, 3);
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(port.reads, 4);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 40));
      expect(port.reads, 4);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPanel(
  WidgetTester tester,
  AccountUsageController controller, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => AccountUsagePanel(controller: controller),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _UsagePort implements AccountUsageRepository {
  _UsagePort({this.overCapacity = false});
  final bool overCapacity;
  int reads = 0;

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>> membership() async {
    reads += 1;
    return MobileAccountUsageResult.success(
      MobileAccountMembership(
        membershipId: 'private-id',
        levelCode: 'pilot_paid',
        status: 'active',
        expiresAt: null,
        monthlyCredit: _monthly,
        permanentCredit: _permanent,
        runAdmission: 'allowed',
        outstandingUncoveredCredits: 0,
      ),
    );
  }

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) async => MobileAccountUsageResult.success(
    MobileAccountCreditPage(
      monthlyCredit: _monthly,
      permanentCredit: _permanent,
      lots: const [],
      runAdmission: 'allowed',
      outstandingUncoveredCredits: 0,
    ),
  );

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async => MobileAccountUsageResult.success(
    MobileWorkspaceStorageUsage(
      userLogicalTotalBytes: overCapacity ? 5368709120 : 1073741824,
      limitBytes: 4294967296,
      remainingBytes: overCapacity ? 0 : 3221225472,
      fileCountLimit: null,
      measurementStatus: 'complete',
      currentContentBytes: 1024,
      retainedHistoryBytes: 512,
      resourceBytes: 1048576,
      logicalTotalBytes: 1050112,
      formalProjectionBytes: 0,
      unmeasuredObjectCount: 0,
      calculatedAt: DateTime.utc(2026, 9, 5),
    ),
  );

  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async => MobileAccountUsageResult.success([
    MobileQuotaBalance(
      quotaType: 'asr_seconds',
      limit: 7200,
      used: 3661.5,
      reserved: 10,
      adjusted: 0,
      remaining: 3528.5,
      uncovered: 0,
      periodStart: DateTime.utc(2026, 9),
      periodEnd: DateTime.utc(2026, 10),
    ),
    const MobileQuotaBalance(
      quotaType: 'generation',
      limit: 100,
      used: 3,
      reserved: 0,
      adjusted: 0,
      remaining: 97,
      uncovered: 0,
    ),
  ]);

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async => const MobileAccountUsageResult.unavailable('NOT_REQUESTED');
}

final _monthly = MobileCreditPool(
  availableCredits: 9000,
  reservedCredits: 100,
  quotaCredits: 10000,
  settledCredits: 900,
  periodStart: DateTime.utc(2026, 9),
  periodEnd: DateTime.utc(2026, 10),
);
const _permanent = MobileCreditPool(availableCredits: 500, reservedCredits: 0);
