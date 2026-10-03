import 'dart:convert';

const positioningProgressLanguage = 'huahuo-positioning-progress';
const positioningTargetFile = 'profile/user-positioning/positioning-profile.md';

enum PositioningModuleState {
  empty,
  seed,
  forming,
  rich,
  readyToUse,
  validated,
  overstated,
}

final class PositioningModuleDefinition {
  const PositioningModuleDefinition(this.id, this.label, this.weight);

  final String id;
  final String label;
  final int weight;
}

const positioningModuleDefinitions = <PositioningModuleDefinition>[
  PositioningModuleDefinition('credible_self', '人生体验', 10),
  PositioningModuleDefinition('audience_person', '典型用户', 10),
  PositioningModuleDefinition('value_destination', '产品与服务', 10),
  PositioningModuleDefinition('entry_scene', '可提供的价值', 10),
  PositioningModuleDefinition('value_delivery', '内容吸引力', 10),
  PositioningModuleDefinition('belief_framework', '观点与判断', 10),
  PositioningModuleDefinition('relationship_persona', '希望和粉丝建立的关系', 20),
  PositioningModuleDefinition('visual_assets', '可调动的影像资源', 20),
];

final class PositioningProgressModule {
  const PositioningProgressModule({
    required this.id,
    required this.label,
    required this.weight,
    required this.score,
    required this.state,
    required this.summary,
    required this.content,
    required this.evidence,
    required this.missing,
    required this.risks,
  });

  final String id;
  final String label;
  final int weight;
  final int score;
  final PositioningModuleState state;
  final String summary;
  final String content;
  final List<String> evidence;
  final List<String> missing;
  final List<String> risks;

  int get percent => ((score / weight) * 100).round().clamp(0, 100).toInt();
}

final class PositioningFocusItem {
  const PositioningFocusItem({
    required this.title,
    required this.detail,
    this.moduleId,
  });

  final String title;
  final String detail;
  final String? moduleId;
}

final class PositioningConsultationState {
  const PositioningConsultationState({
    required this.mode,
    required this.currentSubject,
    required this.subjectGoal,
    required this.subjectStatus,
    required this.confirmedMaterial,
    required this.expertJudgment,
    required this.consequentialGaps,
    required this.recommendedNextSubject,
    required this.userDecision,
    required this.resumePoint,
    required this.dependencies,
    required this.completedSubjects,
  });

  final String mode;
  final String currentSubject;
  final String subjectGoal;
  final String subjectStatus;
  final List<String> confirmedMaterial;
  final String expertJudgment;
  final List<String> consequentialGaps;
  final String recommendedNextSubject;
  final String userDecision;
  final String resumePoint;
  final List<String> dependencies;
  final List<String> completedSubjects;
}

final class PositioningProgressProfile {
  const PositioningProgressProfile({
    required this.targetFile,
    required this.status,
    required this.coldStartPercent,
    required this.coldStartCompleted,
    required this.coldStartStatus,
    required this.completedPercent,
    required this.totalWeight,
    required this.lastUpdated,
    required this.modules,
    required this.nextFocus,
    required this.updatedFiles,
    required this.visibleSubject,
    required this.subjectVersionStatus,
    required this.userDecision,
    required this.consultationState,
  });

  final String targetFile;
  final String status;
  final int coldStartPercent;
  final bool coldStartCompleted;
  final String coldStartStatus;
  final int completedPercent;
  final int totalWeight;
  final String lastUpdated;
  final List<PositioningProgressModule> modules;
  final List<PositioningFocusItem> nextFocus;
  final List<String> updatedFiles;
  final String visibleSubject;
  final String subjectVersionStatus;
  final String userDecision;
  final PositioningConsultationState consultationState;
}

/// Returns the last valid progress block in an assistant or report response.
PositioningProgressProfile? parseLatestPositioningProgress(String text) {
  final blocks = extractPositioningProgressBlocks(text);
  for (var index = blocks.length - 1; index >= 0; index -= 1) {
    final profile = _buildProfile(blocks[index]);
    if (profile != null) return profile;
  }
  return null;
}

/// Parses the structured `positioningProgress` object returned by the current
/// Workspace Profile endpoint. Markdown block extraction remains a fallback
/// for older callers that do not retain this object.
PositioningProgressProfile? parsePositioningProgressPayload(Object? value) {
  final object = _object(value);
  if (object == null || object['available'] == false) return null;
  if (!object.containsKey('completedPercent') &&
      !object.containsKey('coldStartPercent') &&
      object['modules'] is! List) {
    return null;
  }
  return _buildProfile(object);
}

/// Produces a JSON-safe projection for account-scoped report caches.
Map<String, Object?> positioningProgressProfileToPayload(
  PositioningProgressProfile profile,
) => <String, Object?>{
  'available': true,
  'targetFile': profile.targetFile,
  'status': profile.status,
  'coldStartPercent': profile.coldStartPercent,
  'coldStartCompleted': profile.coldStartCompleted,
  'coldStartStatus': profile.coldStartStatus,
  'completedPercent': profile.completedPercent,
  'totalWeight': profile.totalWeight,
  'lastUpdated': profile.lastUpdated,
  'visibleSubject': profile.visibleSubject,
  'subjectVersionStatus': profile.subjectVersionStatus,
  'userDecision': profile.userDecision,
  'modules': <Map<String, Object?>>[
    for (final module in profile.modules)
      <String, Object?>{
        'id': module.id,
        'label': module.label,
        'weight': module.weight,
        'score': module.score,
        'state': _moduleStateValue(module.state),
        'fullnessNote': module.summary,
        'content': module.content,
        'evidence': module.evidence,
        'missing': module.missing,
        'risks': module.risks,
      },
  ],
  'nextFocus': <Map<String, Object?>>[
    for (final focus in profile.nextFocus)
      <String, Object?>{
        'title': focus.title,
        'detail': focus.detail,
        if (focus.moduleId != null) 'moduleId': focus.moduleId,
      },
  ],
  'updatedFiles': profile.updatedFiles,
  'consultationState': <String, Object?>{
    'mode': profile.consultationState.mode,
    'currentSubject': profile.consultationState.currentSubject,
    'subjectGoal': profile.consultationState.subjectGoal,
    'subjectStatus': profile.consultationState.subjectStatus,
    'confirmedMaterial': profile.consultationState.confirmedMaterial,
    'expertJudgment': profile.consultationState.expertJudgment,
    'consequentialGaps': profile.consultationState.consequentialGaps,
    'recommendedNextSubject': profile.consultationState.recommendedNextSubject,
    'userDecision': profile.consultationState.userDecision,
    'resumePoint': profile.consultationState.resumePoint,
    'dependencies': profile.consultationState.dependencies,
    'completedSubjects': profile.consultationState.completedSubjects,
  },
};

List<Map<String, Object?>> extractPositioningProgressBlocks(String text) {
  final result = <Map<String, Object?>>[];
  final fenced = RegExp(
    '```${RegExp.escape(positioningProgressLanguage)}\\s*([\\s\\S]*?)(?:```|\$)',
  );
  for (final match in fenced.allMatches(text)) {
    final parsed = _decodeObject(_firstJsonObject(match.group(1) ?? ''));
    if (parsed != null) result.add(parsed);
  }
  final bare = RegExp('${RegExp.escape(positioningProgressLanguage)}\\s*');
  for (final match in bare.allMatches(text)) {
    if (text.substring(0, match.start).endsWith('```')) continue;
    final parsed = _decodeObject(_firstJsonObject(text.substring(match.end)));
    if (parsed != null) result.add(parsed);
  }
  return List<Map<String, Object?>>.unmodifiable(result);
}

/// Removes parsed progress metadata so the normal Markdown renderer never
/// shows raw JSON below its compact or full dashboard.
String stripPositioningProgressBlocks(String text) {
  var output = text.replaceAll(
    RegExp(
      '```${RegExp.escape(positioningProgressLanguage)}\\s*[\\s\\S]*?(?:```|\$)',
    ),
    '',
  );
  final marker = RegExp('${RegExp.escape(positioningProgressLanguage)}\\s*');
  var match = marker.firstMatch(output);
  while (match != null) {
    final json = _firstJsonObject(output.substring(match.end));
    if (json == null) break;
    output = output.replaceRange(match.start, match.end + json.length, '');
    match = marker.firstMatch(output);
  }
  return output.trim();
}

/// Removes backend-owned document metadata from report presentation while
/// retaining the formal Workspace source unchanged.
String stripPositioningReportMetadata(String text) {
  return stripPositioningProgressBlocks(
    stripPositioningReportFrontmatter(text),
  );
}

/// Removes only a formal positioning document's leading YAML envelope.
String stripPositioningReportFrontmatter(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.isEmpty || lines.first.replaceFirst('\uFEFF', '').trim() != '---') {
    return normalized.trim();
  }
  var closingLine = -1;
  var hasYamlKey = false;
  final yamlKey = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*\s*:');
  for (var index = 1; index < lines.length; index += 1) {
    final line = lines[index];
    if (line.trim() == '---') {
      closingLine = index;
      break;
    }
    if (yamlKey.hasMatch(line.trimLeft())) hasYamlKey = true;
  }
  if (closingLine < 0 || !hasYamlKey) return normalized.trim();
  return lines.skip(closingLine + 1).join('\n').trim();
}

PositioningProgressProfile? _buildProfile(Map<String, Object?> value) {
  final rawModules = value['modules'];
  // Agents can publish the public progress envelope before their first module
  // update. Keep its dashboard visible with the canonical empty modules.
  final modulesSource = rawModules is List ? rawModules : const <Object?>[];
  final totalWeight = _int(value['totalWeight'], 100, min: 1, max: 1000);
  final modules = <PositioningProgressModule>[];
  for (var index = 0; index < positioningModuleDefinitions.length; index += 1) {
    final definition = positioningModuleDefinitions[index];
    final raw = index < modulesSource.length
        ? _object(modulesSource[index])
        : null;
    final weight = _int(raw?['weight'], definition.weight, min: 1, max: 100);
    final state = _state(raw?['state']) ?? PositioningModuleState.empty;
    modules.add(
      PositioningProgressModule(
        id: _text(raw?['moduleId'] ?? raw?['id'], definition.id),
        label: _text(
          raw?['moduleLabel'] ?? raw?['label'] ?? raw?['name'],
          definition.label,
        ),
        weight: weight,
        score: _int(
          raw?['score'],
          _scoreForState(state, weight),
          min: 0,
          max: weight,
        ),
        state: state,
        summary: _text(
          raw?['summary'] ?? raw?['fullnessNote'] ?? raw?['description'],
          '',
        ),
        content: _text(raw?['content'], ''),
        evidence: _strings(raw?['evidence'] ?? raw?['evidenceSources']),
        missing: _strings(
          raw?['missing'] ?? raw?['missingItems'] ?? raw?['questions'],
        ),
        risks: _strings(raw?['risks'] ?? raw?['risk']),
      ),
    );
  }
  final computed =
      ((modules.fold<int>(0, (sum, item) => sum + item.score) / totalWeight) *
              100)
          .round()
          .clamp(0, 100)
          .toInt();
  final consultation = _object(value['consultationState']);
  final subjectStatus = _subjectStatus(
    _text(
      consultation?['subjectStatus'] ?? value['subjectVersionStatus'],
      'exploring',
    ),
  );
  final state = PositioningConsultationState(
    mode: consultation?['mode'] == 'simple' ? 'simple' : 'deep',
    currentSubject: _text(
      consultation?['currentSubject'] ?? value['visibleSubject'],
      '',
    ),
    subjectGoal: _text(consultation?['subjectGoal'], ''),
    subjectStatus: subjectStatus,
    confirmedMaterial: _strings(consultation?['confirmedMaterial']),
    expertJudgment: _text(consultation?['expertJudgment'], ''),
    consequentialGaps: _strings(consultation?['consequentialGaps']),
    recommendedNextSubject: _text(consultation?['recommendedNextSubject'], ''),
    userDecision: _text(
      consultation?['userDecision'] ?? value['userDecision'],
      '',
    ),
    resumePoint: _text(consultation?['resumePoint'], ''),
    dependencies: _strings(consultation?['dependencies']),
    completedSubjects: _strings(consultation?['completedSubjects']),
  );
  final focus = _focus(value['nextFocus']);
  return PositioningProgressProfile(
    targetFile: _safePath(_text(value['targetFile'], positioningTargetFile)),
    status: _text(value['status'], _statusForPercent(computed)),
    coldStartPercent: _int(
      value['coldStartPercent'],
      computed,
      min: 0,
      max: 100,
    ),
    coldStartCompleted: value['coldStartCompleted'] is bool
        ? value['coldStartCompleted']! as bool
        : _int(value['coldStartPercent'], computed, min: 0, max: 100) >= 100,
    coldStartStatus: _text(value['coldStartStatus'], 'collecting'),
    completedPercent: _int(
      value['completedPercent'],
      computed,
      min: 0,
      max: 100,
    ),
    totalWeight: totalWeight,
    lastUpdated: _text(value['lastUpdated'] ?? value['updatedAt'], ''),
    modules: List<PositioningProgressModule>.unmodifiable(modules),
    nextFocus: List<PositioningFocusItem>.unmodifiable(
      focus.isNotEmpty || state.recommendedNextSubject.isEmpty
          ? focus
          : <PositioningFocusItem>[
              PositioningFocusItem(
                title: state.recommendedNextSubject,
                detail: state.resumePoint,
              ),
            ],
    ),
    updatedFiles: _strings(
      value['updatedFiles'],
      max: 6,
    ).map(_safePath).where((item) => item.isNotEmpty).toList(growable: false),
    visibleSubject: state.currentSubject,
    subjectVersionStatus: subjectStatus,
    userDecision: state.userDecision,
    consultationState: state,
  );
}

Map<String, Object?>? _decodeObject(String? source) {
  if (source == null) return null;
  try {
    return _object(jsonDecode(source));
  } on FormatException {
    return null;
  }
}

String? _firstJsonObject(String source) {
  final start = source.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var index = start; index < source.length; index += 1) {
    final char = source[index];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      continue;
    }
    if (char == '"') {
      quoted = true;
    } else if (char == '{') {
      depth += 1;
    } else if (char == '}') {
      depth -= 1;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  return null;
}

Map<String, Object?>? _object(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _text(Object? value, String fallback) {
  if (value is! String) return fallback;
  final text = value.trim();
  return text.isEmpty || text.length > 12000 ? fallback : text;
}

List<String> _strings(Object? value, {int max = 4}) {
  if (value is String && value.trim().isNotEmpty) return <String>[value.trim()];
  if (value is! List) return const <String>[];
  return List<String>.unmodifiable(
    value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty && item.length <= 1200)
        .take(max),
  );
}

int _int(Object? value, int fallback, {required int min, required int max}) {
  if (value is! num || !value.isFinite || value.toInt() != value)
    return fallback;
  return value.toInt().clamp(min, max).toInt();
}

PositioningModuleState? _state(Object? value) {
  final raw = _text(value, '').toLowerCase();
  if (raw.contains('validated') || raw.contains('已验证'))
    return PositioningModuleState.validated;
  if (raw.contains('ready_to_use') || raw.contains('可直接使用'))
    return PositioningModuleState.readyToUse;
  if (raw.contains('rich') ||
      raw.contains('solid') ||
      raw.contains('饱满') ||
      raw.contains('扎实'))
    return PositioningModuleState.rich;
  if (raw.contains('forming') ||
      raw.contains('usable') ||
      raw.contains('成形') ||
      raw.contains('可用'))
    return PositioningModuleState.forming;
  if (raw.contains('overstated') || raw.contains('虚高'))
    return PositioningModuleState.overstated;
  if (raw.contains('seed') ||
      raw.contains('thin') ||
      raw.contains('薄') ||
      raw.contains('线索'))
    return PositioningModuleState.seed;
  if (raw.contains('empty') || raw.contains('空'))
    return PositioningModuleState.empty;
  return null;
}

int _scoreForState(PositioningModuleState state, int weight) => switch (state) {
  PositioningModuleState.validated => weight,
  PositioningModuleState.readyToUse => (weight * .9).round(),
  PositioningModuleState.rich => (weight * .75).round(),
  PositioningModuleState.forming => (weight * .45).round(),
  PositioningModuleState.seed ||
  PositioningModuleState.overstated => (weight * .2).round(),
  PositioningModuleState.empty => 0,
};

String _moduleStateValue(PositioningModuleState state) => switch (state) {
  PositioningModuleState.empty => 'empty',
  PositioningModuleState.seed => 'seed',
  PositioningModuleState.forming => 'forming',
  PositioningModuleState.rich => 'rich',
  PositioningModuleState.readyToUse => 'ready_to_use',
  PositioningModuleState.validated => 'validated',
  PositioningModuleState.overstated => 'overstated',
};

String _statusForPercent(int percent) => switch (percent) {
  >= 95 => 'validated',
  >= 75 => 'ready_to_use',
  >= 45 => 'forming',
  _ => 'draft',
};

String _subjectStatus(String value) => switch (value) {
  'provisional' || 'accepted_for_now' || 'revising' => value,
  _ => 'exploring',
};

List<PositioningFocusItem> _focus(Object? value) {
  if (value is! List) return const <PositioningFocusItem>[];
  final result = <PositioningFocusItem>[];
  for (final raw in value.take(5)) {
    if (raw is String && raw.trim().isNotEmpty) {
      result.add(PositioningFocusItem(title: raw.trim(), detail: ''));
      continue;
    }
    final object = _object(raw);
    if (object == null) continue;
    result.add(
      PositioningFocusItem(
        title: _text(
          object['title'] ?? object['label'] ?? object['moduleLabel'],
          '下一步补充',
        ),
        detail: _text(
          object['detail'] ?? object['reason'] ?? object['question'],
          '',
        ),
        moduleId: _text(object['moduleId'], '').isEmpty
            ? null
            : _text(object['moduleId'], ''),
      ),
    );
  }
  return result;
}

String _safePath(String value) {
  final normalized = value.replaceAll('\\', '/').trim();
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains('..')) {
    return positioningTargetFile;
  }
  return normalized;
}
