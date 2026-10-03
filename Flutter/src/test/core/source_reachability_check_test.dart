import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/source_reachability_check.dart';

void main() {
  test('library parts are reachable without a part-of dependency cycle', () {
    final root = '${Directory.current.path}/part-fixture/lib';
    final graph = buildWorkspaceDependencyGraph(
      <String, String>{
        '$root/main.dart': "part 'details.dart';",
        '$root/details.dart': "part of 'main.dart';",
      },
      <String, String>{'fixture': root},
    );
    expect(graph['$root/main.dart'], contains('$root/details.dart'));
    expect(graph['$root/details.dart'], isEmpty);
    expect(firstDependencyCycle(graph), isNull);
  });

  test('counts physical source lines without a trailing-newline phantom', () {
    expect(sourceLineCount(''), 0);
    expect(sourceLineCount('one'), 1);
    expect(sourceLineCount('one\n'), 1);
    expect(sourceLineCount('one\ntwo'), 2);
    expect(sourceLineCount('one\ntwo\n'), 2);
  });

  test('governed line count excludes only resident-provider markers', () {
    const source = '''
// ordinary architecture note
// resident-provider: Preserves one process identity across route changes.
final runtimeProvider = Provider<Object>((ref) => Object());
''';

    expect(sourceLineCount(source), 3);
    expect(architectureSourceLineCount(source), 2);
  });

  test('classifies Desktop page and business-layer module limits', () {
    expect(
      workspaceModuleLineLimit(
        'desktop/lib/features/editor/presentation/editor_workspace.dart',
      ),
      800,
    );
    expect(
      workspaceModuleLineLimit(
        'desktop/lib/features/chat/application/chat_controller.dart',
      ),
      500,
    );
    expect(
      workspaceModuleLineLimit(
        'packages/huahuo_product/lib/src/data/product_catalog.dart',
      ),
      500,
    );
    expect(
      workspaceModuleLineLimit(
        'desktop/lib/features/editor/application/graph_simulation.dart',
      ),
      isNull,
    );
  });

  test('ratchets oversized Desktop modules to an exact debt budget', () {
    const source = 'one\ntwo\nthree\n';

    expect(
      evaluateWorkspaceModuleSize(
        source,
        'desktop/lib/features/example/presentation/example_page.dart',
        debtBudget: 3,
      ),
      isEmpty,
    );
    expect(
      evaluateWorkspaceModuleSize(
        'one\ntwo\n',
        'desktop/lib/features/example/presentation/example_page.dart',
        debtBudget: 3,
      ).single.code,
      'WORKSPACE MODULE DEBT BUDGET STALE',
    );
    expect(
      evaluateWorkspaceModuleSize(
        'one\ntwo\nthree\nfour\n',
        'desktop/lib/features/example/presentation/example_page.dart',
        debtBudget: 3,
      ).single.code,
      'WORKSPACE MODULE DEBT GREW',
    );
  });

  test(
    'rejects explicit API, client, DAO, and matching provider build calls',
    () {
      const source = r'''
class Example {
  Widget build(BuildContext context) {
    profileApi.load();
    ref.read(accountDaoProvider).query();
    return const SizedBox();
  }
}
''';

      final findings = evaluateArchitectureSource(source);

      expect(
        findings.map((finding) => finding.code),
        contains('BUILD DIRECT IO'),
      );
    },
  );

  test('allows controller queries and masks comments and strings in build', () {
    const source = r'''
class Example {
  Widget build(BuildContext context) {
    // profileApi.load();
    const diagnostic = 'ref.read(accountDaoProvider).query()';
    final note = controller.noteForId('note-id');
    consume(note);
    return Text(diagnostic);
  }
}
''';

    expect(evaluateArchitectureSource(source), isEmpty);
  });

  test('ratchets build microtasks and direct command receivers', () {
    const source = r'''
class Example {
  Widget build(BuildContext context) {
    scheduleMicrotask(controller.refresh);
    Future<void>.microtask(service.start);
    noteRepository.save();
    syncService.start();
    flowController.load();
    recordingPort.stop();
    ref.read(profileRepositoryProvider).save();
    return const SizedBox();
  }
}
''';

    expect(
      evaluateArchitectureSource(source).single.code,
      'BUILD SIDE EFFECT DEBT GREW',
    );
    expect(evaluateArchitectureSource(source, buildSideEffectDebt: 7), isEmpty);
  });

  test('rejects stale build and performance debt allowance', () {
    const buildSource = r'''
class Example {
  Widget build(BuildContext context) {
    scheduleMicrotask(controller.refresh);
    return const SizedBox();
  }
}
''';
    const providerSource = r'''
final runtimeProvider = Provider<Object>((ref) => Object());
''';

    expect(
      evaluateArchitectureSource(
        buildSource,
        buildSideEffectDebt: 2,
      ).single.code,
      'BUILD SIDE EFFECT DEBT BUDGET STALE',
    );
    expect(
      evaluatePerformanceRfcSource(
        providerSource,
        residentProviderDebt: 2,
      ).single.code,
      'RESIDENT PROVIDER DEBT BUDGET STALE',
    );
  });

  test('ratchets page-local literal animation duration and blur sigma', () {
    const source = r'''
const _dialogEnterDuration = Duration(milliseconds: 260);

Widget build(BuildContext context) {
  return AnimatedOpacity(
    duration: const Duration(milliseconds: 160),
    reverseDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 80),
    opacity: 1,
    child: ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: RouteTransition(
        transitionDuration: V3MotionTokens.resolve(
          context,
          const Duration(milliseconds: 170),
        ),
        child: V3LiquidGlassSurface(
          blurSigma: 9,
          filter: MaskFilter.blur(BlurStyle.normal, 2.8),
        ),
      ),
    ),
  );
}
''';

    final finding = evaluatePageLocalEffectTokenSource(source).single;
    expect(finding.code, 'PAGE EFFECT DEBT GREW');
    expect(finding.detail, contains('animation Duration=4'));
    expect(finding.detail, contains('blur sigma=4'));
    expect(
      evaluatePageLocalEffectTokenSource(
        source,
        animationDurationDebt: 4,
        blurSigmaDebt: 4,
      ),
      isEmpty,
    );
    expect(
      evaluatePageLocalEffectTokenSource(
        source,
        animationDurationDebt: 5,
        blurSigmaDebt: 4,
      ).single.code,
      'PAGE EFFECT DEBT BUDGET STALE',
    );
  });

  test('page effect ratchet allows tokens and masks non-code literals', () {
    const source = r'''
// duration: const Duration(milliseconds: 160),
const diagnostic = 'blurSigma: 22';

Widget build(BuildContext context) {
  return AnimatedOpacity(
    duration: V3MotionTokens.quick,
    opacity: 1,
    child: V3LiquidGlassSurface(
      blurSigma: V3GlassEffectTokens.floatingHubSigma,
    ),
  );
}
''';

    expect(evaluatePageLocalEffectTokenSource(source), isEmpty);
  });

  test('effect token scope includes shared consumers but not foundations', () {
    expect(
      isEffectTokenConsumerPath(
        'lib/features/chat/presentation/chat_page.dart',
      ),
      isTrue,
    );
    expect(
      isEffectTokenConsumerPath('lib/shared/ui_v3/v3_components.dart'),
      isTrue,
    );
    expect(
      isEffectTokenConsumerPath(
        'lib/features/settings/widgets/appearance_card.dart',
      ),
      isTrue,
    );
    expect(
      isEffectTokenConsumerPath('lib/shared/ui_v3/v3_glass_foundations.dart'),
      isFalse,
    );
    expect(
      isEffectTokenConsumerPath('lib/core/tasking/task_orchestrator.dart'),
      isFalse,
    );
  });

  test('checks expression build bodies and excludes deferred builders', () {
    const expression = r'''
class Example {
  Widget build(BuildContext context) => apiClient.send();
}
''';
    const nested = r'''
class Example {
  Widget build(BuildContext context) {
    if (ready) {
      return Builder(builder: (_) {
        recordsDao.read();
        return const SizedBox();
      });
    }
    return const SizedBox();
  }
}
''';
    const expressionDeferred = r'''
class Example {
  Widget build(BuildContext context) => ActionSurface(
    onPressed: () {
      flowController.load();
    },
  );
}
''';

    expect(
      evaluateArchitectureSource(expression).single.code,
      'BUILD DIRECT IO',
    );
    expect(evaluateArchitectureSource(nested), isEmpty);
    final deferredFindings = evaluateArchitectureSource(expressionDeferred);
    expect(
      deferredFindings,
      isEmpty,
      reason: deferredFindings
          .map((finding) => '${finding.code}: ${finding.detail}')
          .join('\n'),
    );
  });

  test('keeps switch-expression arms on the eager build path', () {
    const source = r'''
class Example {
  Widget build(BuildContext context) {
    return switch (state) {
      Ready() => flowController.load(),
      (final left, final right) => profileApi.load(),
    };
  }
}
''';

    expect(
      evaluateArchitectureSource(source).map((finding) => finding.code),
      containsAll(<String>['BUILD DIRECT IO', 'BUILD SIDE EFFECT DEBT GREW']),
    );
  });

  test('excludes deferred callbacks but still rejects an eager IIFE', () {
    const deferred = r'''
class Example {
  Widget build(BuildContext context) {
    return ActionSurface(
      onPressed: () {
        recordsDao.read();
        flowController.load();
        scheduleMicrotask(service.start);
      },
      builder: (_) => noteRepository.save(),
      onChanged: (value) async => syncService.save(value),
    );
  }
}
''';
    const immediatelyInvoked = r'''
class Example {
  Widget build(BuildContext context) {
    (() {
      flowController.load();
    })();
    return const SizedBox();
  }
}
''';
    const returnedIife = r'''
class Example {
  Widget build(BuildContext context) {
    return (() {
      flowController.load();
      return const SizedBox();
    })();
  }
}
''';
    const blockCall = r'''
class Example {
  Widget build(BuildContext context) {
    (() {
      flowController.load();
    }).call();
    return const SizedBox();
  }
}
''';
    const arrowCall = r'''
class Example {
  Widget build(BuildContext context) {
    (() => flowController.load()).call();
    return const SizedBox();
  }
}
''';

    expect(evaluateArchitectureSource(deferred), isEmpty);
    expect(
      evaluateArchitectureSource(immediatelyInvoked).single.code,
      'BUILD SIDE EFFECT DEBT GREW',
    );
    expect(
      evaluateArchitectureSource(returnedIife).single.code,
      'BUILD SIDE EFFECT DEBT GREW',
    );
    expect(
      evaluateArchitectureSource(blockCall).single.code,
      'BUILD SIDE EFFECT DEBT GREW',
    );
    expect(
      evaluateArchitectureSource(arrowCall).single.code,
      'BUILD SIDE EFFECT DEBT GREW',
    );
  });

  test('requires cancellation for an owned StreamSubscription', () {
    const uncancelled = r'''
class Owner {
  StreamSubscription<int>? _events;
}
''';
    const cancelled = r'''
class Owner {
  StreamSubscription<int>? _events;

  void dispose() {
    _events?.cancel();
  }
}
''';

    expect(
      evaluateArchitectureSource(uncancelled).single.code,
      'UNCANCELLED STREAM SUBSCRIPTION',
    );
    expect(evaluateArchitectureSource(cancelled), isEmpty);
  });

  test('requires element cancellation for subscription collections', () {
    const uncancelled = r'''
class Owner {
  final _events = <StreamSubscription<Object?>>[];
}
''';
    const cancelled = r'''
class Owner {
  late final List<StreamSubscription<Object?>> _events;

  void dispose() {
    for (final event in _events) {
      event.cancel();
    }
  }
}
''';

    expect(
      evaluateArchitectureSource(uncancelled).single.code,
      'UNCANCELLED STREAM SUBSCRIPTION',
    );
    expect(evaluateArchitectureSource(cancelled), isEmpty);
  });

  test('does not treat a subscription parameter as an owned resource', () {
    const source = r'''
void observe(StreamSubscription<int> subscription) {
  consume(subscription);
}
''';

    expect(evaluateArchitectureSource(source), isEmpty);
  });

  test('requires an activity gate for heavy KeepAlive resources', () {
    const unsafe = r'''
class RetainedPageState extends State<Page>
    with AutomaticKeepAliveClientMixin<Page> {
  Timer? _poller;
}
''';
    const leased = r'''
class RetainedPageState extends State<Page>
    with AutomaticKeepAliveClientMixin<Page> {
  late final PageActivityLease _activityLease;
  Timer? _poller;
}
''';
    const tickerMode = r'''
class RetainedPageState extends State<Page>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin<Page> {
  late final AnimationController _animation;

  Widget build(BuildContext context) {
    return TickerMode(enabled: active, child: const SizedBox());
  }
}
''';

    expect(
      evaluateArchitectureSource(unsafe).single.code,
      'HEAVY KEEPALIVE WITHOUT ACTIVITY GATE',
    );
    expect(evaluateArchitectureSource(leased), isEmpty);
    expect(evaluateArchitectureSource(tickerMode), isEmpty);
  });

  test('rejects an ungated ticker retained by KeepAlive', () {
    const source = r'''
class RetainedPageState extends State<Page>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin<Page> {
  late final AnimationController _animation;
}
''';

    expect(
      evaluateArchitectureSource(source).single.code,
      'HEAVY KEEPALIVE WITHOUT ACTIVITY GATE',
    );
  });

  test('requires a checked-in RFC for new resident TaskSpec registrations', () {
    const missing = r'''
void activate() {
  orchestrator.schedule(TaskSpec(key: 'sync', owner: 'test'));
}
''';
    const approved = r'''
// performance-rfc: bounded-sync
void activate() {
  orchestrator.schedule(TaskSpec(key: 'sync', owner: 'test'));
}
''';
    const unknown = r'''
// performance-rfc: missing-doc
void activate() {
  orchestrator.schedule(TaskSpec(key: 'sync', owner: 'test'));
}
''';

    expect(
      evaluateArchitectureSource(missing).single.code,
      'MISSING PERFORMANCE RFC',
    );
    expect(
      evaluateArchitectureSource(
        approved,
        knownPerformanceRfcs: const <String>{'bounded-sync'},
      ),
      isEmpty,
    );
    expect(
      evaluateArchitectureSource(
        unknown,
        knownPerformanceRfcs: const <String>{'bounded-sync'},
      ).map((finding) => finding.code),
      containsAll(<String>[
        'UNKNOWN PERFORMANCE RFC',
        'MISSING PERFORMANCE RFC',
      ]),
    );
  });

  test('resident providers require one concrete bound reason', () {
    const missing = r'''
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const approved = r'''
// resident-provider: Preserves one process runtime identity across route changes.
/// Shared process runtime dependency.
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const autoDisposed = r'''
final runtimeProvider = Provider.autoDispose<Object>((ref) => Object());
''';

    expect(
      evaluateArchitectureSource(missing).single.code,
      'MISSING RESIDENT PROVIDER REASON',
    );
    expect(evaluateArchitectureSource(approved), isEmpty);
    expect(evaluateArchitectureSource(autoDisposed), isEmpty);
  });

  test('rejects invalid, detached, and duplicate resident reasons', () {
    const invalid = r'''
// resident-provider: TODO: explain the lifecycle later.
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const generic = r'''
// resident-provider: This provider is resident.
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const detached = r'''
// resident-provider: Preserves one process runtime identity across route changes.
const gap01 = 0;
const gap02 = 0;
const gap03 = 0;
const gap04 = 0;
const gap05 = 0;
const gap06 = 0;
const gap07 = 0;
const gap08 = 0;
const gap09 = 0;
const gap10 = 0;
const gap11 = 0;
const gap12 = 0;
const gap13 = 0;
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const duplicate = r'''
// resident-provider: Preserves one process runtime identity across route changes.
// resident-provider: Owns the runtime listener for the full process lifetime.
final runtimeProvider = Provider<Object>((ref) => Object());
''';

    expect(
      evaluateArchitectureSource(invalid).map((finding) => finding.code),
      containsAll(<String>[
        'INVALID RESIDENT PROVIDER REASON',
        'MISSING RESIDENT PROVIDER REASON',
      ]),
    );
    expect(
      evaluateArchitectureSource(detached).map((finding) => finding.code),
      containsAll(<String>[
        'UNBOUND RESIDENT PROVIDER REASON',
        'MISSING RESIDENT PROVIDER REASON',
      ]),
    );
    expect(
      evaluateArchitectureSource(duplicate).single.code,
      'DUPLICATE RESIDENT PROVIDER REASON',
    );
    expect(
      evaluateArchitectureSource(generic).map((finding) => finding.code),
      containsAll(<String>[
        'INVALID RESIDENT PROVIDER REASON',
        'MISSING RESIDENT PROVIDER REASON',
      ]),
    );
  });

  test('ignores marker-shaped strings and block comments', () {
    const source = r"""
const diagnostic = r'''
// resident-provider: Preserves one process identity across route changes.
''';
/*
// resident-provider: Preserves one process identity across route changes.
*/
final runtimeProvider = Provider<Object>((ref) => Object());
""";

    expect(
      evaluateArchitectureSource(source).single.code,
      'MISSING RESIDENT PROVIDER REASON',
    );
    expect(architectureSourceLineCount(source), sourceLineCount(source));
  });

  test('binds resident reasons at 8 lines and rejects 9 lines', () {
    const boundAtEight = r'''
// resident-provider: Preserves one process identity across route changes.
const gap01 = 0;
const gap02 = 0;
const gap03 = 0;
const gap04 = 0;
const gap05 = 0;
const gap06 = 0;
const gap07 = 0;
final runtimeProvider = Provider<Object>((ref) => Object());
''';
    const detachedAtNine = r'''
// resident-provider: Preserves one process identity across route changes.
const gap01 = 0;
const gap02 = 0;
const gap03 = 0;
const gap04 = 0;
const gap05 = 0;
const gap06 = 0;
const gap07 = 0;
const gap08 = 0;
final runtimeProvider = Provider<Object>((ref) => Object());
''';

    expect(evaluateArchitectureSource(boundAtEight), isEmpty);
    expect(
      evaluateArchitectureSource(detachedAtNine).map((finding) => finding.code),
      containsAll(<String>[
        'UNBOUND RESIDENT PROVIDER REASON',
        'MISSING RESIDENT PROVIDER REASON',
      ]),
    );
  });

  test('RFC gate covers task, persistence, and repeating animation', () {
    const source = r'''
// resident-provider: Preserves one process runtime identity across route changes.
final runtimeProvider = Provider<Object>((ref) => Object());

void activate() {
  orchestrator.schedule(TaskSpec(key: 'sync', owner: 'test'));
  final database = AppDatabase();
  sqlite.sqlite3.open(path);
  animation.repeat();
}
''';

    final finding = evaluateArchitectureSource(source).single;
    expect(finding.code, 'MISSING PERFORMANCE RFC');
    expect(finding.detail, contains('TaskSpec=1'));
    expect(finding.detail, contains('database persistence=2'));
    expect(finding.detail, contains('continuous animation=1'));
    expect(
      evaluateArchitectureSource(
        source,
        taskSpecDebt: 1,
        databasePersistenceDebt: 2,
        continuousAnimationDebt: 1,
      ),
      isEmpty,
    );
  });

  test('performance RFC marker cannot be reused by another risk', () {
    const source = r'''
// performance-rfc: bounded-sync
void activate() {
  orchestrator.schedule(TaskSpec(key: 'sync', owner: 'test'));
}

final database = AppDatabase();
''';

    final findings = evaluateArchitectureSource(
      source,
      knownPerformanceRfcs: const <String>{'bounded-sync'},
    );

    expect(
      findings.where((finding) => finding.code == 'MISSING PERFORMANCE RFC'),
      hasLength(1),
    );
    expect(findings.single.detail, contains('database persistence=1'));

    const detached = r'''
// performance-rfc: bounded-sync
const gap01 = 0;
const gap02 = 0;
const gap03 = 0;
const gap04 = 0;
const gap05 = 0;
const gap06 = 0;
const gap07 = 0;
const gap08 = 0;
const gap09 = 0;
const gap10 = 0;
final database = AppDatabase();
''';
    expect(
      evaluateArchitectureSource(
        detached,
        knownPerformanceRfcs: const <String>{'bounded-sync'},
      ).map((finding) => finding.code),
      containsAll(<String>[
        'UNBOUND PERFORMANCE RFC',
        'MISSING PERFORMANCE RFC',
      ]),
    );
  });

  test('workspace boundaries reject app coupling in every direction', () {
    final root = '${Directory.current.path}/workspace-boundary-fixture';
    final roots = <String, String>{
      'huahuoai_app': '$root/src/lib',
      'huahuo_desktop': '$root/desktop/lib',
      'huahuo_foundation': '$root/packages/huahuo_foundation/lib',
    };

    expect(
      evaluateWorkspaceImportBoundaries(
        "import 'package:huahuo_desktop/shell.dart';",
        sourcePath: '$root/src/lib/mobile.dart',
        sourcePackage: 'huahuoai_app',
        packageLibRoots: roots,
      ).single.code,
      'WORKSPACE BOUNDARY',
    );
    expect(
      evaluateWorkspaceImportBoundaries(
        "import 'package:huahuoai_app/main.dart';",
        sourcePath: '$root/desktop/lib/desktop.dart',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
      ).single.code,
      'WORKSPACE BOUNDARY',
    );
    expect(
      evaluateWorkspaceImportBoundaries(
        "import 'package:huahuoai_app/main.dart';",
        sourcePath: '$root/packages/huahuo_foundation/lib/shared.dart',
        sourcePackage: 'huahuo_foundation',
        packageLibRoots: roots,
      ).single.code,
      'WORKSPACE BOUNDARY',
    );
    expect(
      evaluateWorkspaceImportBoundaries(
        "import 'package:huahuo_foundation/model.dart';",
        sourcePath: '$root/src/lib/mobile.dart',
        sourcePackage: 'huahuoai_app',
        packageLibRoots: roots,
      ),
      isEmpty,
    );
  });

  test('workspace boundaries reject relative escapes from a package lib', () {
    final root = '${Directory.current.path}/workspace-boundary-fixture';
    final roots = <String, String>{
      'huahuo_foundation': '$root/packages/huahuo_foundation/lib',
    };

    expect(
      evaluateWorkspaceImportBoundaries(
        "import '../../../src/lib/main.dart';",
        sourcePath: '$root/packages/huahuo_foundation/lib/shared.dart',
        sourcePackage: 'huahuo_foundation',
        packageLibRoots: roots,
      ).single.code,
      'WORKSPACE BOUNDARY',
    );
  });

  test('workspace feature dependencies use exact Desktop ratchets', () {
    final root = '${Directory.current.path}/workspace-feature-fixture';
    final roots = <String, String>{
      'huahuoai_app': '$root/src/lib',
      'huahuo_desktop': '$root/desktop/lib',
      'huahuo_foundation': '$root/packages/huahuo_foundation/lib',
    };
    const source = r'''
import '../data/editor_store.dart';
import '../../chat/presentation/chat_panel.dart';
''';

    final growth = evaluateWorkspaceFeatureDependencySource(
      source,
      sourcePath:
          '$root/desktop/lib/features/editor/presentation/editor_page.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(
      growth.map((finding) => finding.code),
      containsAll(<String>[
        'PRESENTATION DATA DEBT GREW',
        'CROSS FEATURE PRESENTATION DEBT GREW',
      ]),
    );
    expect(
      evaluateWorkspaceFeatureDependencySource(
        source,
        sourcePath:
            '$root/desktop/lib/features/editor/presentation/editor_page.dart',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
        presentationDataDebt: 1,
        crossFeaturePresentationDebt: 1,
      ),
      isEmpty,
    );
    final stale = evaluateWorkspaceFeatureDependencySource(
      source,
      sourcePath:
          '$root/desktop/lib/features/editor/presentation/editor_page.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
      presentationDataDebt: 2,
      crossFeaturePresentationDebt: 2,
    );
    expect(
      stale.map((finding) => finding.code),
      containsAll(<String>[
        'PRESENTATION DATA DEBT BUDGET STALE',
        'CROSS FEATURE PRESENTATION DEBT BUDGET STALE',
      ]),
    );
  });

  test('feature services cannot import presentation libraries', () {
    final root = '${Directory.current.path}/workspace-layer-fixture';
    final roots = <String, String>{
      'huahuoai_app': '$root/src/lib',
      'huahuo_desktop': '$root/desktop/lib',
    };

    final ownPresentation = evaluateWorkspaceFeatureDependencySource(
      "import '../presentation/editor_page.dart';",
      sourcePath:
          '$root/desktop/lib/features/editor/application/editor_service.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(ownPresentation.map((finding) => finding.code), <String>[
      'LAYER REVERSAL',
    ]);

    final otherPresentation = evaluateWorkspaceFeatureDependencySource(
      "import '../../chat/presentation/chat_panel.dart';",
      sourcePath:
          '$root/desktop/lib/features/editor/application/editor_service.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(
      otherPresentation.map((finding) => finding.code),
      containsAll(<String>[
        'LAYER REVERSAL',
        'CROSS FEATURE PRESENTATION DEBT GREW',
      ]),
    );

    expect(
      evaluateWorkspaceFeatureDependencySource(
        "import '../features/editor/presentation/editor_page.dart';",
        sourcePath: '$root/desktop/lib/app/desktop_routes.dart',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
      ),
      isEmpty,
    );
  });

  test('feature widgets are public UI but cannot bypass layer rules', () {
    final root = '${Directory.current.path}/workspace-widget-fixture';
    final roots = <String, String>{
      'huahuoai_app': '$root/src/lib',
      'huahuo_desktop': '$root/desktop/lib',
    };

    expect(
      evaluateWorkspaceFeatureDependencySource(
        "import '../../chat/widgets/chat_badge.dart';",
        sourcePath:
            '$root/desktop/lib/features/editor/presentation/editor_page.dart',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
      ),
      isEmpty,
    );

    final widgetData = evaluateWorkspaceFeatureDependencySource(
      "import '../data/settings_store.dart';",
      sourcePath:
          '$root/desktop/lib/features/settings/widgets/settings_card.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(widgetData.single.code, 'PRESENTATION DATA DEBT GREW');

    final serviceWidget = evaluateWorkspaceFeatureDependencySource(
      "import '../widgets/settings_card.dart';",
      sourcePath:
          '$root/desktop/lib/features/settings/application/settings_service.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(serviceWidget.single.code, 'LAYER REVERSAL');

    final chainedWidgets = evaluateWorkspaceFeatureDependencySource(
      "import '../../chat/widgets/chat_badge.dart';",
      sourcePath:
          '$root/desktop/lib/features/editor/widgets/editor_toolbar.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(chainedWidgets.single.code, 'LAYER REVERSAL');

    final widgetApp = evaluateWorkspaceFeatureDependencySource(
      "import '../../../app/bootstrap/app_providers.dart';",
      sourcePath:
          '$root/desktop/lib/features/settings/widgets/settings_card.dart',
      sourcePackage: 'huahuo_desktop',
      packageLibRoots: roots,
    );
    expect(widgetApp.single.code, 'LAYER REVERSAL');
  });

  test('application may construct data adapters but cannot export data', () {
    final root = '${Directory.current.path}/workspace-export-fixture';
    final roots = <String, String>{'huahuo_desktop': '$root/desktop/lib'};
    const sourcePath =
        '/desktop/lib/features/settings/application/settings_service.dart';

    expect(
      evaluateWorkspaceFeatureDependencySource(
        "import '../data/settings_store.dart';",
        sourcePath: '$root$sourcePath',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
      ),
      isEmpty,
    );
    expect(
      evaluateWorkspaceFeatureDependencySource(
        "export '../data/settings_store.dart';",
        sourcePath: '$root$sourcePath',
        sourcePackage: 'huahuo_desktop',
        packageLibRoots: roots,
      ).single.code,
      'LAYER REVERSAL',
    );
  });

  test('complete desktop graph exposes package and relative cycles', () {
    final root = '${Directory.current.path}/desktop-cycle-fixture';
    final sources = <String, String>{
      '$root/desktop/lib/a.dart': "import 'package:huahuo_desktop/b.dart';",
      '$root/desktop/lib/b.dart': "export 'a.dart';",
    };
    final graph = buildWorkspaceDependencyGraph(sources, <String, String>{
      'huahuo_desktop': '$root/desktop/lib',
    });

    expect(firstDependencyCycle(graph), isNotNull);
  });
}
