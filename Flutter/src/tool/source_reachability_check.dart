import 'dart:io';

const _retiredFileNames = <String>{
  'document_change_proposal_controller.dart',
  'graph_edge_geometry_builder.dart',
  'graph_edge_render_plan.dart',
  'graph_geometry_cache.dart',
  'recording_card_auto_sync_settings.dart',
  'v3_deep_positioning_page.dart',
  'v3_feed_floating_hub.dart',
  'v3_graph_edge_painter.dart',
  'agent_tool_activity_phrase.dart',
  'agent_tool_activity_phrase_catalog.dart',
  'canvas_chat_rewrite_port.dart',
  'recording_card_binding_dao.dart',
  'ui_v3_controller.dart',
  'v3_creation_pages.dart',
  'v3_creation_result_page.dart',
};

const _retiredSymbols = <String>{
  'AgentToolActivityPhrase',
  'CanvasChatRewritePort',
  'CanvasChatRewriteRequest',
  'CanvasChatRewriteResult',
  'RecordingCardBindingDao',
  'UiV3Controller',
  'V3ChoiceField',
  'V3CreationHistoryItem',
  'V3CreationMode',
  'V3DarkGlassSurface',
  'V3DepositsPage',
  'V3FeedMoreNavigationSheet',
  'V3LiquidGlassDock',
  'V3LiquidGlassFrame',
  'V3LocalRecordingLibraryPage',
  'V3MaterialImportTaskSheet',
  'V3ProfileFeaturePlaceholderPage',
  'V3RoundIconButton',
  'V3SparkPlaceholderPage',
  'V3Tag',
  'V3WorkbenchPage',
};

// These are extraction budgets, not permanent exemptions. Every value is the
// current line count and may only decrease until it reaches the 2,500-line
// architecture ceiling.
const _architectureDebtBudgets = <String, int>{
  'lib/features/chat/application/chat_controller.dart': 2949,
  'lib/features/recording_card/application/recording_card_controller.dart':
      3954,
  'lib/features/ui_v3/application/knowledge_library_controller.dart': 4962,
  'lib/features/ui_v3/presentation/v3_chat_page.dart': 6646,
  'lib/features/ui_v3/presentation/v3_creation_canvas_page.dart': 6211,
  'lib/features/ui_v3/presentation/v3_interactive_graph.dart': 3120,
  'lib/shared/ui_v3/v3_liquid_glass.dart': 2728,
};

// These workspace-relative budgets ratchet existing Desktop/shared-package
// modules down toward the standard page/widget and business-layer ceilings.
const _workspaceModuleDebtBudgets = <String, int>{
  'desktop/lib/features/editor/presentation/editor_workspace.dart': 13348,
  'desktop/lib/features/editor/presentation/desktop_knowledge_graph.dart': 2869,
  'desktop/lib/shared/markdown/markdown_preview_pane.dart': 1789,
  'desktop/lib/features/editor/presentation/desktop_graph_settings_controls.dart':
      881,
  'desktop/lib/shared/markdown/markdown_preview_settings_controls.dart': 872,
  'desktop/lib/features/documents/data/desktop_document_sync_adapters.dart':
      947,
  'desktop/lib/features/chat/data/desktop_chat_adapters.dart': 916,
  'desktop/lib/features/agent/application/desktop_agent_controller.dart': 665,
  'desktop/lib/features/auth/data/desktop_auth_adapters.dart': 524,
  'desktop/lib/features/chat/application/desktop_chat_task_tracker.dart': 514,
  'desktop/lib/features/integration/domain/desktop_api_domains_port.dart': 505,
};

const _moduleLineLimits = <String, int>{
  'lib/app/bootstrap/app_root.dart': 650,
  'lib/app/bootstrap/app_visual_root.dart': 500,
  'lib/app/bootstrap/app_providers.dart': 2000,
  'lib/app/bootstrap/core_provider_module.dart': 500,
  'lib/app/bootstrap/app_runtime_activation.dart': 500,
  'lib/app/bootstrap/push_runtime_activation.dart': 500,
  'lib/app/bootstrap/recovery_runtime_activation.dart': 500,
  'lib/app/bootstrap/foreground_resume_coordinator.dart': 500,
  'lib/core/tasking/app_task_projection.dart': 500,
  'lib/core/tasking/orchestrated_poller.dart': 500,
  'lib/core/tasking/task_orchestrator.dart': 500,
  'lib/features/chat/application/chat_runtime_invocation_mapper.dart': 500,
  'lib/features/chat/application/chat_thread_progress_poller.dart': 500,
  'lib/features/ui_v3/application/knowledge_library_query_controller.dart': 550,
  'lib/features/ui_v3/application/knowledge_library_runtime.dart': 500,
  'lib/features/ui_v3/application/knowledge_note_sync_service.dart': 500,
  'lib/features/ui_v3/application/knowledge_subscription_controller.dart': 550,
  'lib/features/ui_v3/application/canvas_autosave_coordinator.dart': 500,
  'lib/features/ui_v3/presentation/v3_chat_execution_process.dart': 500,
  'lib/shared/ui_v3/v3_glass_blur_tokens.dart': 500,
  'lib/shared/ui_v3/v3_glass_foundations.dart': 500,
  'lib/shared/ui_v3/v3_glass_painters.dart': 500,
};

const _buildSideEffectDebtBudgets = <String, int>{};

const _residentProviderDebtBudgets = <String, int>{};

const _databasePersistenceDebtBudgets = <String, int>{
  'lib/app/bootstrap/app_providers.dart': 1,
  'lib/app/runtime/database_worker_runtime.dart': 4,
  'lib/core/database/app_database.dart': 4,
  'lib/core/database/app_preferences_dao.dart': 8,
  'lib/core/database/creation_canvas_draft_dao.dart': 8,
  'lib/core/database/creation_canvas_history_dao.dart': 2,
  'lib/core/database/database_write_queue.dart': 1,
  'lib/core/database/database_worker.dart': 1,
  'lib/core/database/diagnostic_log_dao.dart': 4,
  'lib/core/database/profile_workspace_dao.dart': 3,
  'lib/core/database/recording_dao.dart': 2,
  'lib/core/database/user_metadata_dao.dart': 7,
  'lib/core/database/v3_deposit_dao.dart': 11,
  'lib/features/ingestion/data/material_ingestion_store.dart': 1,
  'lib/features/recording_card/data/recording_card_auto_sync_store.dart': 1,
  'lib/features/recordings/data/local_recording_repository.dart': 4,
  'lib/features/settings/application/settings_controller.dart': 1,
  'lib/features/ui_v3/data/v3_document_import_store.dart': 1,
};

const _continuousAnimationDebtBudgets = <String, int>{
  'lib/features/ui_v3/presentation/v3_chat_execution_process.dart': 1,
  'lib/features/ui_v3/presentation/v3_chat_page.dart': 1,
  'lib/features/ui_v3/presentation/v3_digital_twin_page.dart': 1,
  'lib/shared/ui_v3/v3_components.dart': 1,
  'desktop/lib/features/editor/presentation/desktop_graph_settings_controls.dart':
      1,
};

const _pageLocalAnimationDurationDebtBudgets = <String, int>{};

const _pageLocalBlurSigmaDebtBudgets = <String, int>{};

const _presentationDataDebtBudgets = <String, int>{};

const _crossFeaturePresentationDebtBudgets = <String, int>{};

const _periodicTimerDebtBudgets = <String, int>{
  'lib/features/auth/presentation/auth_screen.dart': 1,
  'lib/features/chat/application/voice_message_controller.dart': 1,
  'lib/features/ingestion/application/internal_recording_controller.dart': 1,
  'lib/features/ingestion/application/meeting_capture_controller.dart': 1,
  'lib/features/recordings/application/monologue_recording_controller.dart': 1,
  'lib/features/ui_v3/application/voiceprint_controller.dart': 1,
  'lib/features/ui_v3/presentation/v3_chat_page.dart': 1,
  'lib/features/ui_v3/presentation/v3_knowledge_local_surfaces.dart': 1,
  'lib/features/ui_v3/presentation/v3_note_append_page.dart': 1,
  'lib/features/ui_v3/presentation/v3_recording_card_control_page.dart': 1,
};

const _bindingObserverDebtBudgets = <String, int>{
  'lib/app/lifecycle/app_activity_coordinator.dart': 1,
};

final _directivePattern = RegExp(
  r'''^\s*(import|export|part)\s+((?:of\s+)?["'][^;]+);''',
  multiLine: true,
);
final _uriPattern = RegExp("['\"]([^'\"]+)['\"]");

void main() {
  final lib = Directory('lib');
  final entry = File('lib/main.dart');
  if (!lib.existsSync() || !entry.existsSync()) {
    stderr.writeln('source_reachability_check must run from Flutter/src');
    exitCode = 2;
    return;
  }

  final sourceRoot = Directory.current.absolute;
  final workspaceRoot = sourceRoot.parent;
  final desktopLib = Directory('${workspaceRoot.path}/desktop/lib');
  final sharedPackages = Directory('${workspaceRoot.path}/packages');
  if (!desktopLib.existsSync() || !sharedPackages.existsSync()) {
    stderr.writeln(
      'workspace architecture roots are missing under ${workspaceRoot.path}',
    );
    exitCode = 2;
    return;
  }

  final sources = _dartSources(lib);
  final reachable = <String>{};
  final graph = <String, Set<String>>{};
  final pending = <String>[entry.absolute.path];
  final knownPerformanceRfcs = _performanceRfcIds(
    Directory('../docs/performance/rfcs'),
  );
  var failed = false;

  final workspaceLibraries = <({String packageName, Directory lib})>[
    (packageName: 'huahuoai_app', lib: lib.absolute),
    (packageName: 'huahuo_desktop', lib: desktopLib.absolute),
  ];
  final sharedRoots = <({String packageName, Directory lib})>[];
  for (final directory
      in sharedPackages.listSync(followLinks: false).whereType<Directory>()) {
    final packageLib = Directory('${directory.path}/lib');
    if (!packageLib.existsSync()) continue;
    final packageName = _pubspecPackageName(
      File('${directory.path}/pubspec.yaml'),
    );
    if (packageName == null) {
      stderr.writeln('SHARED PACKAGE NAME MISSING: ${directory.path}');
      failed = true;
      continue;
    }
    sharedRoots.add((packageName: packageName, lib: packageLib.absolute));
  }
  if (sharedRoots.isEmpty) {
    stderr.writeln('SHARED PACKAGE SCAN EMPTY: ${sharedPackages.path}');
    failed = true;
  }
  workspaceLibraries.addAll(sharedRoots);
  final packageLibRoots = <String, String>{
    for (final library in workspaceLibraries)
      library.packageName: library.lib.absolute.path,
  };
  final workspaceSources = <String, Map<String, File>>{
    for (final library in workspaceLibraries)
      library.packageName: _dartSources(library.lib),
  };

  for (final library in workspaceLibraries) {
    for (final source in workspaceSources[library.packageName]!.values) {
      final content = source.readAsStringSync();
      final displayPath = _workspaceRelativePath(
        source.absolute.path,
        workspaceRoot,
      );
      if (library.packageName != 'huahuoai_app') {
        for (final finding in evaluateWorkspaceModuleSize(
          content,
          displayPath,
          debtBudget: _workspaceModuleDebtBudgets[displayPath],
        )) {
          stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
          failed = true;
        }
      }
      for (final finding in evaluateWorkspaceImportBoundaries(
        content,
        sourcePath: source.absolute.path,
        sourcePackage: library.packageName,
        packageLibRoots: packageLibRoots,
      )) {
        stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
        failed = true;
      }
      if (library.packageName == 'huahuoai_app') continue;
      for (final finding in evaluateWorkspaceFeatureDependencySource(
        content,
        sourcePath: source.absolute.path,
        sourcePackage: library.packageName,
        packageLibRoots: packageLibRoots,
        presentationDataDebt: _presentationDataDebtBudgets[displayPath] ?? 0,
        crossFeaturePresentationDebt:
            _crossFeaturePresentationDebtBudgets[displayPath] ?? 0,
      )) {
        stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
        failed = true;
      }
      if (isEffectTokenConsumerPath(displayPath)) {
        for (final finding in evaluatePageLocalEffectTokenSource(
          content,
          animationDurationDebt:
              _pageLocalAnimationDurationDebtBudgets[displayPath] ?? 0,
          blurSigmaDebt: _pageLocalBlurSigmaDebtBudgets[displayPath] ?? 0,
        )) {
          stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
          failed = true;
        }
      }
      for (final finding in evaluateWidgetBuildSource(
        content,
        buildSideEffectDebt: _buildSideEffectDebtBudgets[displayPath] ?? 0,
      )) {
        stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
        failed = true;
      }
      for (final finding in evaluatePerformanceRfcSource(
        content,
        residentProviderDebt: _residentProviderDebtBudgets[displayPath] ?? 0,
        databasePersistenceDebt:
            _databasePersistenceDebtBudgets[displayPath] ?? 0,
        continuousAnimationDebt:
            _continuousAnimationDebtBudgets[displayPath] ?? 0,
        knownPerformanceRfcs: knownPerformanceRfcs,
      )) {
        stderr.writeln('${finding.code}: $displayPath ${finding.detail}');
        failed = true;
      }
    }
  }

  final desktopContents = <String, String>{
    for (final entry in workspaceSources['huahuo_desktop']!.entries)
      entry.key: entry.value.readAsStringSync(),
  };
  final desktopCycle = firstDependencyCycle(
    buildWorkspaceDependencyGraph(desktopContents, packageLibRoots),
  );
  if (desktopCycle != null) {
    stderr.writeln(
      'DESKTOP DEPENDENCY CYCLE: '
      '${desktopCycle.map((path) => _workspaceRelativePath(path, workspaceRoot)).join(' -> ')}',
    );
    failed = true;
  }

  for (final source in sources.values) {
    final path = _libRelativePath(source.absolute.path);
    final content = source.readAsStringSync();
    final fileName = source.uri.pathSegments.last;
    if (_retiredFileNames.contains(fileName)) {
      stderr.writeln('RETIRED FILE: $path');
      failed = true;
    }
    for (final symbol in _retiredSymbols) {
      if (RegExp('\\b${RegExp.escape(symbol)}\\b').hasMatch(content)) {
        stderr.writeln('RETIRED SYMBOL: $path contains $symbol');
        failed = true;
      }
    }
    final lineCount = sourceLineCount(content);
    final moduleLineCount = architectureSourceLineCount(content);
    final moduleLineLimit = _moduleLineLimits[path];
    if (moduleLineLimit != null && moduleLineCount > moduleLineLimit) {
      stderr.writeln(
        'MODULE SIZE LIMIT: '
        '$path has $moduleLineCount governed lines, limit $moduleLineLimit',
      );
      failed = true;
    }
    final debtBudget = _architectureDebtBudgets[path];
    final isPresentation =
        path.contains('/presentation/') || path.startsWith('lib/shared/ui_v3/');
    if (isEffectTokenConsumerPath(path)) {
      for (final finding in evaluatePageLocalEffectTokenSource(
        content,
        animationDurationDebt:
            _pageLocalAnimationDurationDebtBudgets[path] ?? 0,
        blurSigmaDebt: _pageLocalBlurSigmaDebtBudgets[path] ?? 0,
      )) {
        stderr.writeln('${finding.code}: $path ${finding.detail}');
        failed = true;
      }
    }
    if (debtBudget != null && lineCount > debtBudget) {
      stderr.writeln(
        'PRESENTATION DEBT GREW: $path has $lineCount lines, budget $debtBudget',
      );
      failed = true;
    } else if (debtBudget != null && lineCount < debtBudget) {
      stderr.writeln(
        'PRESENTATION DEBT BUDGET STALE: '
        '$path has $lineCount lines, budget $debtBudget',
      );
      failed = true;
    } else if (isPresentation && debtBudget == null && lineCount > 2500) {
      stderr.writeln('OVERSIZED PRESENTATION: $path has $lineCount lines');
      failed = true;
    }
    for (final finding in evaluateArchitectureSource(
      content,
      buildSideEffectDebt: _buildSideEffectDebtBudgets[path] ?? 0,
      residentProviderDebt: _residentProviderDebtBudgets[path] ?? 0,
      databasePersistenceDebt: _databasePersistenceDebtBudgets[path] ?? 0,
      continuousAnimationDebt: _continuousAnimationDebtBudgets[path] ?? 0,
      knownPerformanceRfcs: knownPerformanceRfcs,
    )) {
      stderr.writeln('${finding.code}: $path ${finding.detail}');
      failed = true;
    }

    failed =
        _checkRatchet(
          label: 'PERIODIC TIMER DEBT GREW',
          path: path,
          count: 'Timer.periodic'.allMatches(content).length,
          budgets: _periodicTimerDebtBudgets,
        ) ||
        failed;
    failed =
        _checkRatchet(
          label: 'BINDING OBSERVER DEBT GREW',
          path: path,
          count: RegExp(r'\.addObserver\(this\)').allMatches(content).length,
          budgets: _bindingObserverDebtBudgets,
        ) ||
        failed;

    var presentationDataImports = 0;
    var crossFeaturePresentationImports = 0;

    for (final directive in _directivePattern.allMatches(content)) {
      final kind = directive.group(1)!;
      final clause = directive.group(2)!;
      if (kind == 'part') {
        final isPartOf = clause.trimLeft().startsWith('of ');
        final partUris = _uriPattern
            .allMatches(clause)
            .map((match) => match.group(1)!)
            .toList(growable: false);
        final generated = isPartOf
            ? _isGeneratedPartPath(path)
            : partUris.isNotEmpty && partUris.every(_isGeneratedPartPath);
        if (!generated) {
          stderr.writeln('HAND-WRITTEN PART DIRECTIVE: $path');
          failed = true;
        }
        if (isPartOf) continue;
      }
      for (final uriMatch in _uriPattern.allMatches(clause)) {
        final target = _resolveTarget(source, uriMatch.group(1)!, sources);
        if (target == null) continue;
        final targetPath = _libRelativePath(target);
        if (_isLayerReversal(path, targetPath)) {
          stderr.writeln('LAYER REVERSAL: $path -> $targetPath');
          failed = true;
        }
        if (_isApplicationDataExport(path, targetPath, kind)) {
          stderr.writeln('LAYER REVERSAL: $path exports $targetPath');
          failed = true;
        }
        if (_isPresentationDataDependency(path, targetPath)) {
          presentationDataImports++;
        }
        if (_isCrossFeaturePresentationDependency(path, targetPath)) {
          crossFeaturePresentationImports++;
        }
      }
    }
    failed =
        _checkRatchet(
          label: 'PRESENTATION DATA DEBT GREW',
          path: path,
          count: presentationDataImports,
          budgets: _presentationDataDebtBudgets,
        ) ||
        failed;
    failed =
        _checkRatchet(
          label: 'CROSS FEATURE PRESENTATION DEBT GREW',
          path: path,
          count: crossFeaturePresentationImports,
          budgets: _crossFeaturePresentationDebtBudgets,
        ) ||
        failed;
  }

  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (!reachable.add(path)) continue;
    final source = sources[path];
    if (source == null) continue;
    final content = source.readAsStringSync();
    final targets = graph.putIfAbsent(path, () => <String>{});
    for (final directive in _directivePattern.allMatches(content)) {
      if (directive.group(1) == 'part' &&
          directive.group(2)!.startsWith('of ')) {
        continue;
      }
      for (final uriMatch in _uriPattern.allMatches(directive.group(2)!)) {
        final target = _resolveTarget(source, uriMatch.group(1)!, sources);
        if (target != null) {
          targets.add(target);
          pending.add(target);
        }
      }
    }
  }

  final unreachable =
      sources.keys.where((path) => !reachable.contains(path)).toList()..sort();
  stdout.writeln(
    'Dart reachability: ${reachable.length}/${sources.length} files',
  );
  final cycle = firstDependencyCycle(graph);
  if (cycle != null) {
    stderr.writeln(
      'DEPENDENCY CYCLE: ${cycle.map(_libRelativePath).join(' -> ')}',
    );
    failed = true;
  }
  if (unreachable.isNotEmpty) {
    for (final path in unreachable) {
      stderr.writeln('UNREACHABLE: ${_libRelativePath(path)}');
    }
    failed = true;
  }
  if (failed) exitCode = 1;
}

int sourceLineCount(String source) {
  if (source.isEmpty) return 0;
  final newlineCount = '\n'.allMatches(source).length;
  return source.endsWith('\n') ? newlineCount : newlineCount + 1;
}

int architectureSourceLineCount(String source) =>
    sourceLineCount(source) - _residentProviderMarkers(source).length;

int? workspaceModuleLineLimit(String path) {
  final normalized = path.replaceAll('\\', '/');
  final fileName = normalized.split('/').last;
  if (normalized.contains('/presentation/') ||
      normalized.contains('/widgets/') ||
      fileName.endsWith('_page.dart') ||
      fileName.endsWith('_workspace.dart') ||
      fileName.endsWith('_pane.dart') ||
      fileName.endsWith('_controls.dart')) {
    return 800;
  }
  if (normalized.contains('/data/') ||
      fileName.endsWith('_controller.dart') ||
      fileName.endsWith('_tracker.dart') ||
      fileName.endsWith('_repository.dart') ||
      fileName.endsWith('_port.dart')) {
    return 500;
  }
  return null;
}

List<ArchitectureSourceFinding> evaluateWorkspaceModuleSize(
  String source,
  String path, {
  int? debtBudget,
}) {
  final limit = workspaceModuleLineLimit(path);
  if (limit == null) return const <ArchitectureSourceFinding>[];
  final lines = sourceLineCount(source);
  if (debtBudget != null) {
    if (lines > debtBudget) {
      return <ArchitectureSourceFinding>[
        ArchitectureSourceFinding(
          'WORKSPACE MODULE DEBT GREW',
          'has $lines lines, budget $debtBudget, target $limit',
        ),
      ];
    }
    if (lines < debtBudget) {
      return <ArchitectureSourceFinding>[
        ArchitectureSourceFinding(
          'WORKSPACE MODULE DEBT BUDGET STALE',
          'has $lines lines, budget $debtBudget, target $limit',
        ),
      ];
    }
    return const <ArchitectureSourceFinding>[];
  }
  if (lines > limit) {
    return <ArchitectureSourceFinding>[
      ArchitectureSourceFinding(
        'OVERSIZED WORKSPACE MODULE',
        'has $lines lines, limit $limit',
      ),
    ];
  }
  return const <ArchitectureSourceFinding>[];
}

final class ArchitectureSourceFinding {
  const ArchitectureSourceFinding(this.code, this.detail);

  final String code;
  final String detail;
}

List<ArchitectureSourceFinding> evaluatePageLocalEffectTokenSource(
  String source, {
  int animationDurationDebt = 0,
  int blurSigmaDebt = 0,
}) {
  final code = _maskDartNonCode(source);
  final animationDurations =
      RegExp(
        r'\b(?:duration|[A-Za-z_]\w*Duration)\s*:\s*[^,;]{0,240}?'
        r'(?:const\s+)?Duration\s*\(',
      ).allMatches(code).length +
      RegExp(
        r'\b(?:const|final)\s+(?:Duration\s+)?[A-Za-z_]\w*Duration\s*='
        r'\s*(?:const\s+)?Duration\s*\(',
      ).allMatches(code).length +
      RegExp(
        r'\bV3MotionTokens\s*\.\s*resolve\s*\([^,;]+,\s*'
        r'(?:const\s+)?Duration\s*\(',
      ).allMatches(code).length;
  final blurSigmas =
      RegExp(
        r'\b(?:sigmaX|sigmaY|[A-Za-z_]\w*Sigma)\s*:\s*[^,;]{0,160}?'
        r'-?(?:\d+(?:\.\d*)?|\.\d+)\b',
      ).allMatches(code).length +
      RegExp(
        r'\b(?:const|final)\s+(?:double\s+)?[A-Za-z_]\w*Sigma\s*='
        r'\s*-?(?:\d+(?:\.\d*)?|\.\d+)\b',
      ).allMatches(code).length +
      RegExp(
        r'\b(?:[A-Za-z_]\w*\.)?MaskFilter\s*\.\s*blur\s*\([^,;]+,'
        r'\s*[^);]{0,240}?-?(?:\d+(?:\.\d*)?|\.\d+)\b',
      ).allMatches(code).length;
  final detail =
      'animation Duration=$animationDurations, budget=$animationDurationDebt; '
      'blur sigma=$blurSigmas, budget=$blurSigmaDebt';
  final findings = <ArchitectureSourceFinding>[];
  if (animationDurations > animationDurationDebt ||
      blurSigmas > blurSigmaDebt) {
    findings.add(ArchitectureSourceFinding('PAGE EFFECT DEBT GREW', detail));
  }
  if (animationDurations < animationDurationDebt ||
      blurSigmas < blurSigmaDebt) {
    findings.add(
      ArchitectureSourceFinding('PAGE EFFECT DEBT BUDGET STALE', detail),
    );
  }
  return findings;
}

bool isEffectTokenConsumerPath(String path) =>
    path.contains('/presentation/') ||
    path.contains('/widgets/') ||
    (path.startsWith('lib/shared/ui_v3/') &&
        !path.endsWith('/v3_glass_foundations.dart'));

List<ArchitectureSourceFinding> evaluateWidgetBuildSource(
  String source, {
  int buildSideEffectDebt = 0,
}) => _evaluateWidgetBuildCode(
  _maskDartNonCode(source),
  buildSideEffectDebt: buildSideEffectDebt,
);

List<ArchitectureSourceFinding> evaluateArchitectureSource(
  String source, {
  int buildSideEffectDebt = 0,
  int taskSpecDebt = 0,
  int residentProviderDebt = 0,
  int databasePersistenceDebt = 0,
  int continuousAnimationDebt = 0,
  Set<String> knownPerformanceRfcs = const <String>{},
}) {
  final code = _maskDartNonCode(source);
  final findings = _evaluateWidgetBuildCode(
    code,
    buildSideEffectDebt: buildSideEffectDebt,
  );
  final individualOwners = RegExp(
    r'\bStreamSubscription(?:\s*<[^;\n]+>)?\s*\??\s+'
    r'([A-Za-z_]\w*)\s*(?=[=;])',
  ).allMatches(code).map((match) => match.group(1)!).toSet();
  final collectionOwners = <String>{
    ...RegExp(
      r'\b(?:List|Set|Iterable|Map)\s*<[^;\n]*StreamSubscription'
      r'[^;\n]*>\s+([A-Za-z_]\w*)\s*(?=[=;])',
    ).allMatches(code).map((match) => match.group(1)!),
    ...RegExp(
      r'\b(?:final|var)\s+([A-Za-z_]\w*)\s*=\s*'
      r'<\s*StreamSubscription\b[^;\n]*',
    ).allMatches(code).map((match) => match.group(1)!),
  };
  individualOwners.removeAll(collectionOwners);
  for (final owner in individualOwners) {
    if (!_hasIndividualCancellation(code, owner)) {
      findings.add(
        ArchitectureSourceFinding(
          'UNCANCELLED STREAM SUBSCRIPTION',
          '`$owner` has no matching cancel call',
        ),
      );
    }
  }
  for (final owner in collectionOwners) {
    if (!_hasCollectionCancellation(code, owner)) {
      findings.add(
        ArchitectureSourceFinding(
          'UNCANCELLED STREAM SUBSCRIPTION',
          'collection `$owner` has no element cancellation path',
        ),
      );
    }
  }
  for (final entry in _heavyKeepAliveClasses(code)) {
    final body = entry.body;
    final ownsLease = RegExp(r'\bPageActivityLease\b').hasMatch(body);
    final ownsExternalResource = RegExp(
      r'\b(?:Timer|StreamSubscription|AudioPlayer|VideoPlayerController|'
      r'CameraController)\b',
    ).hasMatch(body);
    final ownsTicker = RegExp(
      r'\b(?:AnimationController|Ticker)\b',
    ).hasMatch(body);
    final tickerIsGated = RegExp(r'\bTickerMode\s*\(').hasMatch(body);
    if (!ownsLease && (ownsExternalResource || ownsTicker && !tickerIsGated)) {
      findings.add(
        ArchitectureSourceFinding(
          'HEAVY KEEPALIVE WITHOUT ACTIVITY GATE',
          '`${entry.name}` retains active resources while kept alive',
        ),
      );
    }
  }
  findings.addAll(
    evaluatePerformanceRfcSource(
      source,
      taskSpecDebt: taskSpecDebt,
      residentProviderDebt: residentProviderDebt,
      databasePersistenceDebt: databasePersistenceDebt,
      continuousAnimationDebt: continuousAnimationDebt,
      knownPerformanceRfcs: knownPerformanceRfcs,
    ),
  );
  return findings;
}

List<ArchitectureSourceFinding> _evaluateWidgetBuildCode(
  String code, {
  required int buildSideEffectDebt,
}) {
  final findings = <ArchitectureSourceFinding>[];
  final explicitIoReceiver = RegExp(
    r'\b[A-Za-z_]\w*(?:api|client|dao)\s*(?:\?|!)?\s*\.\s*[A-Za-z_]\w*\s*\(',
    caseSensitive: false,
  );
  final ioProviderReceiver = RegExp(
    r'\bref\s*\.\s*(?:read|watch)\s*\([^()]*?'
    r'(?:api|client|dao)Provider\b[^()]*?\)\s*(?:\?|!)?\s*\.'
    r'\s*[A-Za-z_]\w*\s*\(',
    caseSensitive: false,
  );
  var buildSideEffectCount = 0;
  for (final body in _widgetBuildBodies(code)) {
    final eagerBody = _eagerBuildCode(body);
    final match =
        explicitIoReceiver.firstMatch(eagerBody) ??
        ioProviderReceiver.firstMatch(eagerBody);
    if (match != null) {
      findings.add(
        ArchitectureSourceFinding(
          'BUILD DIRECT IO',
          'contains `${match.group(0)!.trim()}`',
        ),
      );
    }
    buildSideEffectCount += _buildSideEffects(eagerBody);
  }
  if (buildSideEffectCount > buildSideEffectDebt) {
    findings.add(
      ArchitectureSourceFinding(
        'BUILD SIDE EFFECT DEBT GREW',
        'has $buildSideEffectCount occurrence(s), '
            'budget $buildSideEffectDebt',
      ),
    );
  } else if (buildSideEffectCount < buildSideEffectDebt) {
    findings.add(
      ArchitectureSourceFinding(
        'BUILD SIDE EFFECT DEBT BUDGET STALE',
        'has $buildSideEffectCount occurrence(s), '
            'budget $buildSideEffectDebt',
      ),
    );
  }
  return findings;
}

int _buildSideEffects(String buildBody) {
  final microtasks = RegExp(
    r'\bscheduleMicrotask\s*\(|'
    r'\bFuture(?:\s*<[^>{};]+>)?\s*\.\s*microtask\s*\(',
  ).allMatches(buildBody).length;
  final commandReceiver = RegExp(
    r'\b[A-Za-z_]\w*(?:repository|service|controller|port)\s*'
    r'(?:\?|!)?\s*\.\s*(?:'
    r'acknowledge|activate|add|append|apply|attach|begin|bind|cancel|clear|'
    r'close|commit|complete|confirm|connect|copy|create|deactivate|delete|'
    r'detach|disable|discard|disconnect|dismiss|download|emit|enable|ensure|'
    r'execute|export|fetch|finish|flush|handle|hide|import|initialize|insert|'
    r'join|leave|load|login|logout|mark|merge|move|navigate|notify|open|pause|'
    r'persist|pin|play|post|prepare|process|publish|pull|queue|record|recover|'
    r'refresh|register|reject|remove|rename|reorder|replace|request|reset|'
    r'resolve|restart|restore|resume|retry|revoke|run|save|schedule|select|'
    r'send|set|share|show|sign|start|stop|submit|synchronize|sync|toggle|track|'
    r'trigger|unarchive|unbind|unlink|unpin|unregister|update|upload|upsert|'
    r'write)[A-Za-z0-9_]*\s*\(',
    caseSensitive: false,
  );
  final commandProviderReceiver = RegExp(
    r'\bref\s*\.\s*(?:read|watch)\s*\([^()]*?'
    r'(?:repository|service|controller|port)Provider\b[^()]*?\)\s*'
    r'(?:\?|!)?\s*\.\s*(?:'
    r'acknowledge|activate|add|append|apply|attach|begin|bind|cancel|clear|'
    r'close|commit|complete|confirm|connect|copy|create|deactivate|delete|'
    r'detach|disable|discard|disconnect|dismiss|download|emit|enable|ensure|'
    r'execute|export|fetch|finish|flush|handle|hide|import|initialize|insert|'
    r'join|leave|load|login|logout|mark|merge|move|navigate|notify|open|pause|'
    r'persist|pin|play|post|prepare|process|publish|pull|queue|record|recover|'
    r'refresh|register|reject|remove|rename|reorder|replace|request|reset|'
    r'resolve|restart|restore|resume|retry|revoke|run|save|schedule|select|'
    r'send|set|share|show|sign|start|stop|submit|synchronize|sync|toggle|track|'
    r'trigger|unarchive|unbind|unlink|unpin|unregister|update|upload|upsert|'
    r'write)[A-Za-z0-9_]*\s*\(',
    caseSensitive: false,
  );
  return microtasks +
      commandReceiver.allMatches(buildBody).length +
      commandProviderReceiver.allMatches(buildBody).length;
}

String _eagerBuildCode(String buildBody) {
  final result = buildBody.codeUnits.toList(growable: false);
  final deferredRanges = <({int start, int end})>[];
  for (var index = 0; index < buildBody.length; index++) {
    if (buildBody.codeUnitAt(index) == 0x7B &&
        _isClosureBlockAt(buildBody, index)) {
      final closeBrace = _matchingBrace(buildBody, index);
      if (closeBrace != null &&
          !_isImmediatelyInvokedClosure(buildBody, closeBrace + 1)) {
        deferredRanges.add((start: index + 1, end: closeBrace));
      }
      continue;
    }
    if (index + 1 >= buildBody.length ||
        buildBody.codeUnitAt(index) != 0x3D ||
        buildBody.codeUnitAt(index + 1) != 0x3E ||
        !_isArrowClosureAt(buildBody, index)) {
      continue;
    }
    final expressionEnd = _arrowExpressionEnd(buildBody, index + 2);
    if (!_isImmediatelyInvokedClosure(buildBody, expressionEnd)) {
      deferredRanges.add((start: index + 2, end: expressionEnd));
    }
  }
  for (final range in deferredRanges) {
    for (var index = range.start; index < range.end; index++) {
      if (result[index] != 0x0A && result[index] != 0x0D) {
        result[index] = 0x20;
      }
    }
  }
  return String.fromCharCodes(result);
}

bool _isClosureBlockAt(String code, int openBrace) {
  var cursor = _previousNonWhitespace(code, openBrace - 1);
  if (cursor >= 0 && code.codeUnitAt(cursor) == 0x2A) {
    cursor = _previousNonWhitespace(code, cursor - 1);
  }
  final modifier = _identifierEndingAt(code, cursor);
  if (modifier == 'async' || modifier == 'sync') {
    cursor = _previousNonWhitespace(code, cursor - modifier.length);
  }
  if (cursor < 0 || code.codeUnitAt(cursor) != 0x29) return false;
  final openParenthesis = _matchingOpeningParenthesis(code, cursor);
  if (openParenthesis == null) return false;
  const controlFlow = <String>{
    'assert',
    'catch',
    'for',
    'if',
    'switch',
    'while',
  };
  return !controlFlow.contains(
    _identifierEndingAt(
      code,
      _previousNonWhitespace(code, openParenthesis - 1),
    ),
  );
}

bool _isArrowClosureAt(String code, int arrow) {
  if (_isSwitchExpressionArm(code, arrow)) return false;
  var cursor = _previousNonWhitespace(code, arrow - 1);
  if (cursor >= 0 && code.codeUnitAt(cursor) == 0x2A) {
    cursor = _previousNonWhitespace(code, cursor - 1);
  }
  final modifier = _identifierEndingAt(code, cursor);
  if (modifier == 'async' || modifier == 'sync') {
    cursor = _previousNonWhitespace(code, cursor - modifier.length);
  }
  if (cursor < 0) return false;
  if (code.codeUnitAt(cursor) == 0x29) {
    final openParenthesis = _matchingOpeningParenthesis(code, cursor);
    if (openParenthesis == null) return false;
    return _identifierEndingAt(
          code,
          _previousNonWhitespace(code, openParenthesis - 1),
        ) !=
        'switch';
  }
  final parameter = _identifierEndingAt(code, cursor);
  if (parameter.isEmpty) return false;
  final beforeParameter = _previousNonWhitespace(
    code,
    cursor - parameter.length,
  );
  if (beforeParameter < 0) return true;
  return const <int>{
    0x28,
    0x3A,
    0x3D,
  }.contains(code.codeUnitAt(beforeParameter));
}

bool _isSwitchExpressionArm(String code, int arrow) {
  final braceStack = <int>[];
  for (var index = 0; index < arrow; index++) {
    final value = code.codeUnitAt(index);
    if (value == 0x7B) braceStack.add(index);
    if (value == 0x7D && braceStack.isNotEmpty) braceStack.removeLast();
  }
  int? switchBrace;
  for (final openBrace in braceStack.reversed) {
    final closeParenthesis = _previousNonWhitespace(code, openBrace - 1);
    if (closeParenthesis < 0 || code.codeUnitAt(closeParenthesis) != 0x29) {
      continue;
    }
    final openParenthesis = _matchingOpeningParenthesis(code, closeParenthesis);
    if (openParenthesis != null &&
        _identifierEndingAt(
              code,
              _previousNonWhitespace(code, openParenthesis - 1),
            ) ==
            'switch') {
      switchBrace = openBrace;
      break;
    }
  }
  if (switchBrace == null) return false;

  var parenthesisDepth = 0;
  var bracketDepth = 0;
  var braceDepth = 0;
  var priorArmArrow = false;
  var statementSwitch = false;
  for (var index = switchBrace + 1; index < arrow; index++) {
    final value = code.codeUnitAt(index);
    final atTopLevel =
        parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0;
    if (atTopLevel && _isIdentifierCodeUnit(value)) {
      var end = index + 1;
      while (end < arrow && _isIdentifierCodeUnit(code.codeUnitAt(end))) {
        end++;
      }
      final word = code.substring(index, end);
      if (word == 'case' || word == 'default') statementSwitch = true;
      index = end - 1;
      continue;
    }
    if (atTopLevel && value == 0x2C) {
      priorArmArrow = false;
      continue;
    }
    if (atTopLevel &&
        value == 0x3D &&
        index + 1 < arrow &&
        code.codeUnitAt(index + 1) == 0x3E) {
      priorArmArrow = true;
      index++;
      continue;
    }
    if (value == 0x28) parenthesisDepth++;
    if (value == 0x5B) bracketDepth++;
    if (value == 0x7B) braceDepth++;
    if (value == 0x29 && parenthesisDepth > 0) parenthesisDepth--;
    if (value == 0x5D && bracketDepth > 0) bracketDepth--;
    if (value == 0x7D && braceDepth > 0) braceDepth--;
  }
  return !statementSwitch &&
      !priorArmArrow &&
      parenthesisDepth == 0 &&
      bracketDepth == 0 &&
      braceDepth == 0;
}

int _arrowExpressionEnd(String code, int start) {
  var parenthesisDepth = 0;
  var bracketDepth = 0;
  var braceDepth = 0;
  for (var index = start; index < code.length; index++) {
    final value = code.codeUnitAt(index);
    if (value == 0x28) parenthesisDepth++;
    if (value == 0x5B) bracketDepth++;
    if (value == 0x7B) braceDepth++;
    if (value == 0x29) {
      if (parenthesisDepth == 0) return index;
      parenthesisDepth--;
    }
    if (value == 0x5D) {
      if (bracketDepth == 0) return index;
      bracketDepth--;
    }
    if (value == 0x7D) {
      if (braceDepth == 0) return index;
      braceDepth--;
    }
    if (parenthesisDepth == 0 &&
        bracketDepth == 0 &&
        braceDepth == 0 &&
        (value == 0x2C || value == 0x3B)) {
      return index;
    }
  }
  return code.length;
}

bool _isImmediatelyInvokedClosure(String code, int afterClosure) {
  var cursor = _nextNonWhitespace(code, afterClosure);
  if (_isClosureInvocationAt(code, cursor)) return true;
  while (cursor < code.length && code.codeUnitAt(cursor) == 0x29) {
    final openParenthesis = _matchingOpeningParenthesis(code, cursor);
    if (openParenthesis == null ||
        !_isGroupingParenthesis(code, openParenthesis)) {
      return false;
    }
    cursor = _nextNonWhitespace(code, cursor + 1);
  }
  return _isClosureInvocationAt(code, cursor);
}

bool _isClosureInvocationAt(String code, int cursor) {
  if (cursor >= code.length) return false;
  if (code.codeUnitAt(cursor) == 0x28) return true;
  if (code.codeUnitAt(cursor) != 0x2E) return false;
  final methodStart = _nextNonWhitespace(code, cursor + 1);
  const method = 'call';
  final methodEnd = methodStart + method.length;
  if (methodEnd > code.length ||
      code.substring(methodStart, methodEnd) != method ||
      methodEnd < code.length &&
          _isIdentifierCodeUnit(code.codeUnitAt(methodEnd))) {
    return false;
  }
  final argumentStart = _nextNonWhitespace(code, methodEnd);
  return argumentStart < code.length && code.codeUnitAt(argumentStart) == 0x28;
}

bool _isGroupingParenthesis(String code, int openParenthesis) {
  final previous = _previousNonWhitespace(code, openParenthesis - 1);
  if (previous < 0) return true;
  if (const <String>{
    'await',
    'return',
    'throw',
    'yield',
  }.contains(_identifierEndingAt(code, previous))) {
    return true;
  }
  final value = code.codeUnitAt(previous);
  return !_isIdentifierCodeUnit(value) && value != 0x29 && value != 0x5D;
}

int? _matchingOpeningParenthesis(String code, int closeParenthesis) {
  var depth = 0;
  for (var index = closeParenthesis; index >= 0; index--) {
    final value = code.codeUnitAt(index);
    if (value == 0x29) depth++;
    if (value != 0x28) continue;
    depth--;
    if (depth == 0) return index;
  }
  return null;
}

int _previousNonWhitespace(String code, int start) {
  var cursor = start;
  while (cursor >= 0 && code.codeUnitAt(cursor) <= 0x20) {
    cursor--;
  }
  return cursor;
}

int _nextNonWhitespace(String code, int start) {
  var cursor = start;
  while (cursor < code.length && code.codeUnitAt(cursor) <= 0x20) {
    cursor++;
  }
  return cursor;
}

String _identifierEndingAt(String code, int end) {
  if (end < 0 || !_isIdentifierCodeUnit(code.codeUnitAt(end))) return '';
  var start = end;
  while (start > 0 && _isIdentifierCodeUnit(code.codeUnitAt(start - 1))) {
    start--;
  }
  return code.substring(start, end + 1);
}

Iterable<({String name, String body})> _heavyKeepAliveClasses(
  String code,
) sync* {
  final declaration = RegExp(
    r'\bclass\s+([A-Za-z_]\w*)[^;{]*\bAutomaticKeepAliveClientMixin\b'
    r'[^;{]*\{',
    multiLine: true,
  );
  for (final match in declaration.allMatches(code)) {
    final openBrace = match.end - 1;
    final closeBrace = _matchingBrace(code, openBrace);
    yield (
      name: match.group(1)!,
      body: code.substring(openBrace + 1, closeBrace ?? code.length),
    );
  }
}

List<ArchitectureSourceFinding> evaluatePerformanceRfcSource(
  String source, {
  int taskSpecDebt = 0,
  int residentProviderDebt = 0,
  int databasePersistenceDebt = 0,
  int continuousAnimationDebt = 0,
  Set<String> knownPerformanceRfcs = const <String>{},
}) {
  final code = _maskDartNonCode(source);
  final findings = _evaluateResidentProviderReasons(
    source,
    code,
    residentProviderDebt: residentProviderDebt,
  );
  final markers = RegExp(
    r'^\s*//\s*performance-rfc:\s*([a-z0-9][a-z0-9_-]{1,63})\s*$',
    multiLine: true,
  ).allMatches(source).toList(growable: false);
  final risks = <({String category, int start})>[
    for (final match in RegExp(r'\bTaskSpec\s*\((?!\s*\{)').allMatches(code))
      (category: 'TaskSpec', start: match.start),
    for (final match in RegExp(
      r'\b(?:DatabaseWorker\s*\.\s*start|DatabaseWriteQueue|'
      r'LocalDatabaseSnapshotStore|AppDatabase)\s*\(|'
      r'\b(?:sqlite3|sqlite\s*\.\s*sqlite3)\s*\.\s*open\s*\(|'
      r'\.\s*(?:upsertRecord|deleteRecord|withTransaction|flushPersistence|'
      r'runMigrations|clearUserScopedLocalData|enqueueAppend)\s*\(',
    ).allMatches(code))
      (category: 'database persistence', start: match.start),
    for (final match in RegExp(r'\.\s*repeat\s*\(').allMatches(code))
      (category: 'continuous animation', start: match.start),
  ]..sort((left, right) => left.start.compareTo(right.start));
  final approvedRiskIndexes = <int>{};
  for (final marker in markers) {
    final id = marker.group(1)!;
    if (!knownPerformanceRfcs.contains(id)) {
      findings.add(
        ArchitectureSourceFinding(
          'UNKNOWN PERFORMANCE RFC',
          '`$id` has no docs/performance/rfcs/$id.md',
        ),
      );
      continue;
    }
    int? approvedIndex;
    for (var index = 0; index < risks.length; index++) {
      if (approvedRiskIndexes.contains(index)) continue;
      final distance = risks[index].start - marker.end;
      if (distance < 0) continue;
      if (distance > 160) break;
      approvedIndex = index;
      break;
    }
    if (approvedIndex == null) {
      findings.add(
        ArchitectureSourceFinding(
          'UNBOUND PERFORMANCE RFC',
          '`$id` must precede one risk occurrence within 160 characters',
        ),
      );
    } else {
      approvedRiskIndexes.add(approvedIndex);
    }
  }
  final unapprovedRiskCounts = <String, int>{
    'TaskSpec': 0,
    'database persistence': 0,
    'continuous animation': 0,
  };
  for (var index = 0; index < risks.length; index++) {
    if (approvedRiskIndexes.contains(index)) continue;
    final category = risks[index].category;
    unapprovedRiskCounts[category] = unapprovedRiskCounts[category]! + 1;
  }
  final debtCounts = <String, int>{
    'TaskSpec': taskSpecDebt,
    'database persistence': databasePersistenceDebt,
    'continuous animation': continuousAnimationDebt,
  };
  final newRiskCounts = <String, int>{};
  for (final entry in unapprovedRiskCounts.entries) {
    final debt = debtCounts[entry.key]!;
    if (entry.value < debt) {
      findings.add(
        ArchitectureSourceFinding(
          'PERFORMANCE DEBT BUDGET STALE',
          '${entry.key}=${entry.value}, budget=$debt',
        ),
      );
    } else if (entry.value > debt) {
      newRiskCounts[entry.key] = entry.value - debt;
    }
  }
  if (newRiskCounts.isNotEmpty) {
    final unapproved = newRiskCounts.values.fold<int>(
      0,
      (total, count) => total + count,
    );
    final summary = newRiskCounts.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(', ');
    findings.add(
      ArchitectureSourceFinding(
        'MISSING PERFORMANCE RFC',
        '$unapproved new risk(s) lack a bound RFC marker ($summary)',
      ),
    );
  }
  return findings;
}

List<ArchitectureSourceFinding> _evaluateResidentProviderReasons(
  String source,
  String code, {
  required int residentProviderDebt,
}) {
  final findings = <ArchitectureSourceFinding>[];
  final providers = RegExp(
    r'\b(?:AsyncNotifierProvider|ChangeNotifierProvider|FutureProvider|'
    r'NotifierProvider|Provider|StateNotifierProvider|StateProvider|'
    r'StreamProvider)\b(?!\s*\.\s*autoDispose)(?=[^;=]{0,500}\()',
  ).allMatches(code).toList(growable: false);
  final markers = _residentProviderMarkers(source);
  final approvedProviders = <int>{};
  for (final marker in markers) {
    final reason = marker.group(1)!.trim();
    if (!_isConcreteResidentProviderReason(reason)) {
      findings.add(
        ArchitectureSourceFinding(
          'INVALID RESIDENT PROVIDER REASON',
          '`$reason` must state a concrete lifecycle or identity need',
        ),
      );
      continue;
    }
    final providerIndex = providers.indexWhere(
      (provider) => provider.start >= marker.end,
    );
    final separation = providerIndex < 0
        ? null
        : source.substring(marker.end, providers[providerIndex].start);
    if (separation == null || '\n'.allMatches(separation).length > 8) {
      findings.add(
        ArchitectureSourceFinding(
          'UNBOUND RESIDENT PROVIDER REASON',
          '`$reason` must precede the next resident Provider within 8 lines',
        ),
      );
      continue;
    }
    if (!approvedProviders.add(providerIndex)) {
      findings.add(
        ArchitectureSourceFinding(
          'DUPLICATE RESIDENT PROVIDER REASON',
          'more than one marker targets the same Provider declaration',
        ),
      );
    }
  }
  final unapproved = providers.length - approvedProviders.length;
  if (unapproved > residentProviderDebt) {
    findings.add(
      ArchitectureSourceFinding(
        'MISSING RESIDENT PROVIDER REASON',
        'has $unapproved unapproved resident Provider declaration(s), '
            'budget $residentProviderDebt',
      ),
    );
  } else if (unapproved < residentProviderDebt) {
    findings.add(
      ArchitectureSourceFinding(
        'RESIDENT PROVIDER DEBT BUDGET STALE',
        'has $unapproved unapproved resident Provider declaration(s), '
            'budget $residentProviderDebt',
      ),
    );
  }
  return findings;
}

bool _isConcreteResidentProviderReason(String reason) {
  if (reason.length < 12) return false;
  if (RegExp(
    r'^(?:todo|tbd|placeholder)\b|'
    r'^(?:this\s+)?provider\s+(?:is\s+)?resident\b',
    caseSensitive: false,
  ).hasMatch(reason)) {
    return false;
  }
  return RegExp(
    r'\b(?:account|app(?:lication)?|cache|consumer|controller|durable|identity|'
    r'lifecycle|process|queue|routes?|runtime|scope|session|shared|sibling|'
    r'stable|state|workspace)\b|'
    r'生命周期|身份|会话|账户|账号|路由|进程|全局|共享|状态|缓存|队列|工作区|应用',
    caseSensitive: false,
  ).hasMatch(reason);
}

List<RegExpMatch> _residentProviderMarkers(String source) =>
    RegExp(
          r'^[ \t]*//[ \t]*resident-provider:[ \t]*(.*?)[ \t]*$',
          multiLine: true,
        )
        .allMatches(_maskDartNonCode(source, preserveLineComments: true))
        .toList(growable: false);

Iterable<String> _widgetBuildBodies(String code) sync* {
  final declaration = RegExp(
    r'\bWidget\s+build\s*\([^;{}()]*\)\s*(?:async\s*)?(\{|=>)',
    multiLine: true,
  );
  for (final match in declaration.allMatches(code)) {
    if (match.group(1) == '=>') {
      final end = _expressionStatementEnd(code, match.end);
      yield code.substring(match.end, end);
      continue;
    }
    final openBrace = match.end - 1;
    final closeBrace = _matchingBrace(code, openBrace);
    yield code.substring(openBrace + 1, closeBrace ?? code.length);
  }
}

int _expressionStatementEnd(String code, int start) {
  var parenthesisDepth = 0;
  var bracketDepth = 0;
  var braceDepth = 0;
  for (var index = start; index < code.length; index++) {
    final value = code.codeUnitAt(index);
    if (value == 0x28) parenthesisDepth++;
    if (value == 0x5B) bracketDepth++;
    if (value == 0x7B) braceDepth++;
    if (value == 0x29 && parenthesisDepth > 0) parenthesisDepth--;
    if (value == 0x5D && bracketDepth > 0) bracketDepth--;
    if (value == 0x7D && braceDepth > 0) braceDepth--;
    if (value == 0x3B &&
        parenthesisDepth == 0 &&
        bracketDepth == 0 &&
        braceDepth == 0) {
      return index;
    }
  }
  return code.length;
}

int? _matchingBrace(String code, int openBrace) {
  var depth = 0;
  for (var index = openBrace; index < code.length; index++) {
    final value = code.codeUnitAt(index);
    if (value == 0x7B) depth++;
    if (value != 0x7D) continue;
    depth--;
    if (depth == 0) return index;
  }
  return null;
}

bool _hasIndividualCancellation(String code, String owner) {
  if (_hasDirectCancellation(code, owner)) return true;
  final escaped = RegExp.escape(owner);
  final aliases = RegExp(
    '\\b(?:final|var)\\s+([A-Za-z_]\\w*)\\s*=\\s*$escaped\\s*;',
  ).allMatches(code);
  return aliases.any((match) => _hasDirectCancellation(code, match.group(1)!));
}

bool _hasDirectCancellation(String code, String owner) => RegExp(
  '\\b${RegExp.escape(owner)}\\s*(?:\\?|!)?\\s*\\.\\s*cancel\\s*\\(',
).hasMatch(code);

bool _hasCollectionCancellation(String code, String owner) {
  final escaped = RegExp.escape(owner);
  return RegExp(
    '(?:\\bin\\s+$escaped(?:\\s*\\.\\s*values)?\\b|'
    '\\b$escaped\\s*\\.\\s*(?:values\\s*\\.\\s*)?'
    '(?:map|forEach)\\s*\\()'
    '[\\s\\S]{0,400}?\\b[A-Za-z_]\\w*\\s*\\.\\s*cancel\\s*\\(',
  ).hasMatch(code);
}

String _maskDartNonCode(String source, {bool preserveLineComments = false}) {
  final result = source.codeUnits.toList(growable: false);
  var index = 0;
  void mask(int position) {
    if (result[position] != 0x0A && result[position] != 0x0D) {
      result[position] = 0x20;
    }
  }

  while (index < result.length) {
    if (index + 1 < result.length &&
        result[index] == 0x2F &&
        result[index + 1] == 0x2F) {
      while (index < result.length && result[index] != 0x0A) {
        if (preserveLineComments) {
          index++;
        } else {
          mask(index++);
        }
      }
      continue;
    }
    if (index + 1 < result.length &&
        result[index] == 0x2F &&
        result[index + 1] == 0x2A) {
      var depth = 0;
      while (index < result.length) {
        if (index + 1 < result.length &&
            source.codeUnitAt(index) == 0x2F &&
            source.codeUnitAt(index + 1) == 0x2A) {
          depth++;
          mask(index++);
          mask(index++);
          continue;
        }
        if (index + 1 < result.length &&
            source.codeUnitAt(index) == 0x2A &&
            source.codeUnitAt(index + 1) == 0x2F) {
          depth--;
          mask(index++);
          mask(index++);
          if (depth == 0) break;
          continue;
        }
        mask(index++);
      }
      continue;
    }
    final quote = result[index];
    if (quote != 0x22 && quote != 0x27) {
      index++;
      continue;
    }
    final raw =
        index > 0 &&
        (source.codeUnitAt(index - 1) == 0x72 ||
            source.codeUnitAt(index - 1) == 0x52) &&
        (index < 2 || !_isIdentifierCodeUnit(source.codeUnitAt(index - 2)));
    final triple =
        index + 2 < result.length &&
        result[index + 1] == quote &&
        result[index + 2] == quote;
    final delimiterLength = triple ? 3 : 1;
    for (var offset = 0; offset < delimiterLength; offset++) {
      mask(index++);
    }
    while (index < result.length) {
      if (!raw && result[index] == 0x5C) {
        mask(index++);
        if (index < result.length) mask(index++);
        continue;
      }
      final closes = triple
          ? index + 2 < result.length &&
                result[index] == quote &&
                result[index + 1] == quote &&
                result[index + 2] == quote
          : result[index] == quote;
      if (closes) {
        for (var offset = 0; offset < delimiterLength; offset++) {
          mask(index++);
        }
        break;
      }
      mask(index++);
    }
  }
  return String.fromCharCodes(result);
}

bool _isIdentifierCodeUnit(int value) =>
    value == 0x5F ||
    value >= 0x30 && value <= 0x39 ||
    value >= 0x41 && value <= 0x5A ||
    value >= 0x61 && value <= 0x7A;

List<ArchitectureSourceFinding> evaluateWorkspaceImportBoundaries(
  String source, {
  required String sourcePath,
  required String sourcePackage,
  required Map<String, String> packageLibRoots,
}) {
  final findings = <ArchitectureSourceFinding>[];
  final sourceRoot = packageLibRoots[sourcePackage];
  if (sourceRoot == null) {
    return <ArchitectureSourceFinding>[
      ArchitectureSourceFinding(
        'WORKSPACE BOUNDARY',
        'has no registered library root for package:$sourcePackage',
      ),
    ];
  }
  for (final directive in _directivePattern.allMatches(source)) {
    for (final uriMatch in _uriPattern.allMatches(directive.group(2)!)) {
      final uri = uriMatch.group(1)!;
      final packageMatch = RegExp(r'^package:([^/]+)/').firstMatch(uri);
      if (packageMatch != null) {
        final targetPackage = packageMatch.group(1)!;
        if (_forbiddenWorkspaceDependency(sourcePackage, targetPackage)) {
          findings.add(
            ArchitectureSourceFinding(
              'WORKSPACE BOUNDARY',
              'package:$sourcePackage must not depend on '
                  'package:$targetPackage',
            ),
          );
        }
        continue;
      }
      if (uri.contains(':')) continue;
      final target = File.fromUri(
        File(sourcePath).absolute.parent.uri.resolve(uri),
      ).absolute.path;
      if (!_pathIsWithin(target, sourceRoot)) {
        findings.add(
          ArchitectureSourceFinding(
            'WORKSPACE BOUNDARY',
            'relative directive `$uri` escapes package:$sourcePackage/lib',
          ),
        );
      }
    }
  }
  return findings;
}

List<ArchitectureSourceFinding> evaluateWorkspaceFeatureDependencySource(
  String source, {
  required String sourcePath,
  required String sourcePackage,
  required Map<String, String> packageLibRoots,
  int presentationDataDebt = 0,
  int crossFeaturePresentationDebt = 0,
}) {
  final normalizedRoots = <String, String>{
    for (final entry in packageLibRoots.entries)
      entry.key: _normalizeDirectoryPath(entry.value),
  };
  final sourceRoot = normalizedRoots[sourcePackage];
  if (sourceRoot == null) return const <ArchitectureSourceFinding>[];
  final sourceLayerPath = _packageLibRelativePath(sourcePath, sourceRoot);
  if (sourceLayerPath == null) return const <ArchitectureSourceFinding>[];
  var presentationDataImports = 0;
  var crossFeaturePresentationImports = 0;
  final layerReversals = <String>[];
  for (final directive in _directivePattern.allMatches(source)) {
    final kind = directive.group(1)!;
    if (kind == 'part') continue;
    for (final uriMatch in _uriPattern.allMatches(directive.group(2)!)) {
      final target = _resolveWorkspaceTarget(
        sourcePath,
        uriMatch.group(1)!,
        normalizedRoots,
      );
      if (target == null) continue;
      final targetLayerPath = _workspacePackageLibPath(target, normalizedRoots);
      if (targetLayerPath == null) continue;
      if (_isLayerReversal(sourceLayerPath, targetLayerPath)) {
        layerReversals.add('$sourceLayerPath -> $targetLayerPath');
      }
      if (_isApplicationDataExport(sourceLayerPath, targetLayerPath, kind)) {
        layerReversals.add('$sourceLayerPath exports $targetLayerPath');
      }
      if (_isPresentationDataDependency(sourceLayerPath, targetLayerPath)) {
        presentationDataImports++;
      }
      if (_isCrossFeaturePresentationDependency(
        sourceLayerPath,
        targetLayerPath,
      )) {
        crossFeaturePresentationImports++;
      }
    }
  }
  final findings = <ArchitectureSourceFinding>[
    for (final reversal in layerReversals)
      ArchitectureSourceFinding('LAYER REVERSAL', reversal),
  ];
  void check(String label, int count, int debt) {
    if (count == debt) return;
    findings.add(
      ArchitectureSourceFinding(
        count > debt ? '$label DEBT GREW' : '$label DEBT BUDGET STALE',
        'has $count occurrence(s), budget $debt',
      ),
    );
  }

  check('PRESENTATION DATA', presentationDataImports, presentationDataDebt);
  check(
    'CROSS FEATURE PRESENTATION',
    crossFeaturePresentationImports,
    crossFeaturePresentationDebt,
  );
  return findings;
}

String? _workspacePackageLibPath(
  String path,
  Map<String, String> packageLibRoots,
) {
  for (final root in packageLibRoots.values) {
    final relative = _packageLibRelativePath(path, root);
    if (relative != null) return relative;
  }
  return null;
}

String? _packageLibRelativePath(String path, String root) {
  final normalizedPath = _normalizeFilePath(path);
  final normalizedRoot = _normalizeDirectoryPath(root);
  final prefix = '$normalizedRoot${Platform.pathSeparator}';
  if (!normalizedPath.startsWith(prefix)) return null;
  return 'lib/${normalizedPath.substring(prefix.length).replaceAll('\\', '/')}';
}

Map<String, Set<String>> buildWorkspaceDependencyGraph(
  Map<String, String> sources,
  Map<String, String> packageLibRoots,
) {
  final normalizedSources = <String, String>{
    for (final entry in sources.entries)
      _normalizeFilePath(entry.key): entry.value,
  };
  final normalizedRoots = <String, String>{
    for (final entry in packageLibRoots.entries)
      entry.key: _normalizeDirectoryPath(entry.value),
  };
  final graph = <String, Set<String>>{
    for (final path in normalizedSources.keys) path: <String>{},
  };
  for (final entry in normalizedSources.entries) {
    for (final directive in _directivePattern.allMatches(entry.value)) {
      if (directive.group(1) == 'part' &&
          directive.group(2)!.startsWith('of ')) {
        continue;
      }
      for (final uriMatch in _uriPattern.allMatches(directive.group(2)!)) {
        final target = _resolveWorkspaceTarget(
          entry.key,
          uriMatch.group(1)!,
          normalizedRoots,
        );
        if (target != null && normalizedSources.containsKey(target)) {
          graph[entry.key]!.add(target);
        }
      }
    }
  }
  return graph;
}

String? _resolveWorkspaceTarget(
  String sourcePath,
  String uri,
  Map<String, String> packageLibRoots,
) {
  final packageMatch = RegExp(r'^package:([^/]+)/(.*)$').firstMatch(uri);
  if (packageMatch != null) {
    final root = packageLibRoots[packageMatch.group(1)!];
    if (root == null) return null;
    return _normalizeFilePath('${root}/${packageMatch.group(2)!}');
  }
  if (uri.contains(':')) return null;
  return _normalizeFilePath(
    File.fromUri(File(sourcePath).parent.uri.resolve(uri)).path,
  );
}

bool _forbiddenWorkspaceDependency(String source, String target) {
  if (source == 'huahuoai_app') return target == 'huahuo_desktop';
  if (source == 'huahuo_desktop') return target == 'huahuoai_app';
  return target == 'huahuoai_app' || target == 'huahuo_desktop';
}

bool _pathIsWithin(String path, String directory) {
  final normalizedPath = _normalizeFilePath(path);
  final normalizedDirectory = _normalizeDirectoryPath(directory);
  return normalizedPath == normalizedDirectory ||
      normalizedPath.startsWith(
        '$normalizedDirectory${Platform.pathSeparator}',
      );
}

String _normalizeFilePath(String path) =>
    File(path).absolute.uri.normalizePath().toFilePath();

String _normalizeDirectoryPath(String path) => Directory(path).absolute.uri
    .normalizePath()
    .toFilePath()
    .replaceFirst(RegExp(r'[/\\]+$'), '');

Map<String, File> _dartSources(Directory directory) => <String, File>{
  for (final entity in directory.listSync(recursive: true, followLinks: false))
    if (entity is File && entity.path.endsWith('.dart'))
      entity.absolute.path: entity,
};

String? _pubspecPackageName(File pubspec) {
  if (!pubspec.existsSync()) return null;
  return RegExp(
    r'^name:\s*([A-Za-z_][A-Za-z0-9_]*)\s*$',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?.group(1);
}

String _workspaceRelativePath(String path, Directory workspaceRoot) {
  final normalizedPath = _normalizeFilePath(path);
  final normalizedRoot = _normalizeDirectoryPath(workspaceRoot.path);
  final prefix = '$normalizedRoot${Platform.pathSeparator}';
  return normalizedPath.startsWith(prefix)
      ? normalizedPath.substring(prefix.length).replaceAll('\\', '/')
      : normalizedPath.replaceAll('\\', '/');
}

String? _resolveTarget(File source, String uri, Map<String, File> sources) {
  String? target;
  if (uri.startsWith('package:huahuoai_app/')) {
    target = File(
      'lib/${uri.substring('package:huahuoai_app/'.length)}',
    ).absolute.path;
  } else if (!uri.contains(':')) {
    target = File.fromUri(source.parent.uri.resolve(uri)).absolute.path;
  }
  return target != null && sources.containsKey(target) ? target : null;
}

bool _isLayerReversal(String source, String target) {
  if (source.startsWith('lib/shared/') &&
      (target.startsWith('lib/app/') || target.startsWith('lib/features/'))) {
    return true;
  }
  final domain = RegExp(r'^lib/features/[^/]+/domain/');
  if (domain.hasMatch(source)) {
    return _isFeatureUiLayer(target) ||
        target.contains('/application/') ||
        target.contains('/data/') ||
        target.startsWith('lib/app/');
  }
  if (_featureName(source) == null) return false;
  if ((source.contains('/application/') || source.contains('/data/')) &&
      _isFeatureUiLayer(target)) {
    return true;
  }
  if (source.contains('/widgets/') && target.contains('/presentation/')) {
    return true;
  }
  if (source.contains('/widgets/') && target.startsWith('lib/app/')) {
    return true;
  }
  return source.contains('/widgets/') &&
      target.contains('/widgets/') &&
      _featureName(source) != _featureName(target);
}

bool _isApplicationDataExport(String source, String target, String kind) =>
    kind == 'export' &&
    source.contains('/application/') &&
    target.contains('/data/');

bool _isPresentationDataDependency(String source, String target) =>
    _isFeatureUiLayer(source) && target.contains('/data/');

bool _isCrossFeaturePresentationDependency(String source, String target) {
  final sourceFeature = _featureName(source);
  final targetFeature = _featureName(target);
  return sourceFeature != null &&
      targetFeature != null &&
      sourceFeature != targetFeature &&
      target.contains('/presentation/');
}

bool _isFeatureUiLayer(String path) =>
    path.contains('/presentation/') || path.contains('/widgets/');

bool _isGeneratedPartPath(String path) =>
    path.endsWith('.g.dart') || path.endsWith('.freezed.dart');

Set<String> _performanceRfcIds(Directory directory) {
  if (!directory.existsSync()) return const <String>{};
  return <String>{
    for (final entity in directory.listSync(followLinks: false))
      if (entity is File && entity.path.endsWith('.md'))
        entity.uri.pathSegments.last.substring(
          0,
          entity.uri.pathSegments.last.length - 3,
        ),
  };
}

String? _featureName(String path) {
  final match = RegExp(r'^lib/features/([^/]+)/').firstMatch(path);
  return match?.group(1);
}

bool _checkRatchet({
  required String label,
  required String path,
  required int count,
  required Map<String, int> budgets,
}) {
  final budget = budgets[path] ?? 0;
  if (count == budget) return false;
  if (count > budget) {
    stderr.writeln('$label: $path has $count, budget $budget');
    return true;
  }
  final debtLabel = label.endsWith(' GREW')
      ? label.substring(0, label.length - ' GREW'.length)
      : label;
  stderr.writeln('$debtLabel BUDGET STALE: $path has $count, budget $budget');
  return true;
}

List<String>? firstDependencyCycle(Map<String, Set<String>> graph) {
  final state = <String, int>{};
  final stack = <String>[];

  List<String>? visit(String node) {
    state[node] = 1;
    stack.add(node);
    for (final target in graph[node] ?? const <String>{}) {
      if (state[target] == 1) {
        final start = stack.indexOf(target);
        return <String>[...stack.sublist(start), target];
      }
      if (state[target] == null) {
        final cycle = visit(target);
        if (cycle != null) return cycle;
      }
    }
    stack.removeLast();
    state[node] = 2;
    return null;
  }

  for (final node in graph.keys) {
    if (state[node] != null) continue;
    final cycle = visit(node);
    if (cycle != null) return cycle;
  }
  return null;
}

String _libRelativePath(String path) =>
    File(path).uri.pathSegments.skipWhile((part) => part != 'lib').join('/');
