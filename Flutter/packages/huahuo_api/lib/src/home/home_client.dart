import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

enum HomePrimaryActionType {
  openRunningTask,
  viewHotspotSuggestion,
  uploadRecording,
}

final class HomePrimaryAction {
  const HomePrimaryAction({
    required this.type,
    required this.label,
    this.taskId,
    this.suggestionId,
  });

  factory HomePrimaryAction.fromValue(Object? value) {
    final object = _requiredObject(value, 'primaryAction');
    final type = switch (_requiredString(object, 'type')) {
      'open_running_task' => HomePrimaryActionType.openRunningTask,
      'view_hotspot_suggestion' => HomePrimaryActionType.viewHotspotSuggestion,
      'upload_recording' => HomePrimaryActionType.uploadRecording,
      _ => throw const FormatException('Unsupported Home primary action'),
    };
    final taskId = _optionalIdentifier(object, 'taskId');
    final suggestionId = _optionalIdentifier(object, 'suggestionId');
    if (type == HomePrimaryActionType.openRunningTask && taskId == null) {
      throw const FormatException('Home running-task action requires taskId');
    }
    if (type == HomePrimaryActionType.viewHotspotSuggestion &&
        suggestionId == null) {
      throw const FormatException('Home hotspot action requires suggestionId');
    }
    return HomePrimaryAction(
      type: type,
      label: _requiredString(object, 'label'),
      taskId: taskId,
      suggestionId: suggestionId,
    );
  }

  final HomePrimaryActionType type;
  final String label;
  final String? taskId;
  final String? suggestionId;
}

final class HomeRunningTask {
  const HomeRunningTask({
    required this.taskId,
    required this.taskType,
    required this.status,
    required this.retryable,
    this.threadId,
    this.messageId,
  });

  factory HomeRunningTask.fromValue(Object? value) {
    final object = _requiredObject(value, 'runningTask');
    return HomeRunningTask(
      taskId: _requiredIdentifier(object, 'taskId'),
      taskType: _requiredString(object, 'taskType'),
      status: _requiredString(object, 'status'),
      retryable: _requiredBool(object, 'retryable'),
      threadId: _optionalIdentifier(object, 'threadId'),
      messageId: _optionalIdentifier(object, 'messageId'),
    );
  }

  final String taskId;
  final String taskType;
  final String status;
  final bool retryable;
  final String? threadId;
  final String? messageId;
}

final class HomeHotspotSuggestion {
  HomeHotspotSuggestion({
    required this.suggestionId,
    required this.title,
    required this.summary,
    required this.eventBrief,
    required Iterable<String> discussionPoints,
    required Iterable<String> topicAngles,
    this.sourceName,
  }) : discussionPoints = List<String>.unmodifiable(discussionPoints),
       topicAngles = List<String>.unmodifiable(topicAngles);

  factory HomeHotspotSuggestion.fromValue(Object? value) {
    final object = _requiredObject(value, 'hotspotSuggestion');
    return HomeHotspotSuggestion(
      suggestionId: _requiredIdentifier(object, 'suggestionId'),
      title: _requiredString(object, 'title'),
      summary: _optionalString(object, 'summary'),
      eventBrief: _optionalString(object, 'eventBrief'),
      discussionPoints: _stringList(object['discussionPoints']),
      topicAngles: _stringList(object['topicAngles']),
      sourceName: _optionalString(object, 'sourceName'),
    );
  }

  final String suggestionId;
  final String title;
  final String? summary;
  final String? eventBrief;
  final List<String> discussionPoints;
  final List<String> topicAngles;
  final String? sourceName;
}

final class HomeFileSummary {
  const HomeFileSummary({
    required this.recordingCount,
    required this.depositedRecordingCount,
  });

  factory HomeFileSummary.fromValue(Object? value) {
    final object = _requiredObject(value, 'fileSummary');
    return HomeFileSummary(
      recordingCount: _requiredCount(object, 'recordingCount'),
      depositedRecordingCount: _requiredCount(
        object,
        'depositedRecordingCount',
      ),
    );
  }

  final int recordingCount;
  final int depositedRecordingCount;
}

final class HomeQuotaBalance {
  const HomeQuotaBalance({required this.quotaType, required this.remaining});

  factory HomeQuotaBalance.fromValue(Object? value) {
    final object = _requiredObject(value, 'quota balance');
    return HomeQuotaBalance(
      quotaType: _requiredString(object, 'quotaType'),
      remaining: _requiredNumber(object, 'remainingAmount'),
    );
  }

  final String quotaType;
  final num remaining;
}

final class HomeRedDot {
  const HomeRedDot({
    required this.scope,
    required this.mergeKey,
    required this.count,
  });

  factory HomeRedDot.fromValue(Object? value) {
    final object = _requiredObject(value, 'redDot');
    return HomeRedDot(
      scope: _requiredString(object, 'scope'),
      mergeKey: _requiredIdentifier(object, 'mergeKey'),
      count: _requiredCount(object, 'count'),
    );
  }

  final String scope;
  final String mergeKey;
  final int count;
}

final class HomeSnapshot {
  HomeSnapshot({
    required this.primaryAction,
    required this.hotspotSuggestion,
    required Iterable<HomeRunningTask> runningTasks,
    required this.fileSummary,
    required Iterable<HomeQuotaBalance> quotaBalances,
    required Iterable<HomeRedDot> redDots,
    required this.serverTime,
  }) : runningTasks = List<HomeRunningTask>.unmodifiable(runningTasks),
       quotaBalances = List<HomeQuotaBalance>.unmodifiable(quotaBalances),
       redDots = List<HomeRedDot>.unmodifiable(redDots);

  factory HomeSnapshot.fromValue(Object? value) {
    final object = _requiredObject(value, 'Home response');
    final hotspot = _requiredObject(
      object['hotspotSuggestion'],
      'hotspotSuggestion',
    );
    final quota = _requiredObject(object['quotaSummary'], 'quotaSummary');
    return HomeSnapshot(
      primaryAction: HomePrimaryAction.fromValue(object['primaryAction']),
      hotspotSuggestion: hotspot.isEmpty
          ? null
          : HomeHotspotSuggestion.fromValue(hotspot),
      runningTasks: _objectList(
        object['runningTasks'],
        'runningTasks',
      ).map(HomeRunningTask.fromValue),
      fileSummary: HomeFileSummary.fromValue(object['fileSummary']),
      quotaBalances: _objectList(
        quota['balances'],
        'quotaSummary.balances',
      ).map(HomeQuotaBalance.fromValue),
      redDots: _objectList(
        object['redDots'],
        'redDots',
      ).map(HomeRedDot.fromValue),
      serverTime: _requiredDate(object, 'serverTime'),
    );
  }

  final HomePrimaryAction primaryAction;
  final HomeHotspotSuggestion? hotspotSuggestion;
  final List<HomeRunningTask> runningTasks;
  final HomeFileSummary fileSummary;
  final List<HomeQuotaBalance> quotaBalances;
  final List<HomeRedDot> redDots;
  final DateTime serverTime;
}

final class HomeHotspotViewedReceipt {
  HomeHotspotViewedReceipt({
    required this.suggestionId,
    required this.viewedAt,
    required Iterable<HomeRedDot> redDots,
  }) : redDots = List<HomeRedDot>.unmodifiable(redDots);

  factory HomeHotspotViewedReceipt.fromValue(Object? value) {
    final object = _requiredObject(value, 'Home viewed receipt');
    return HomeHotspotViewedReceipt(
      suggestionId: _requiredIdentifier(object, 'suggestionId'),
      viewedAt: _requiredDate(object, 'viewedAt'),
      redDots: _objectList(
        object['redDots'],
        'redDots',
      ).map(HomeRedDot.fromValue),
    );
  }

  final String suggestionId;
  final DateTime viewedAt;
  final List<HomeRedDot> redDots;
}

final class HomeClient {
  const HomeClient(this._api);

  final ApiClient _api;

  Future<ApiResult<HomeSnapshot>> load() => _api.request<HomeSnapshot>(
    ApiRequestOptions<HomeSnapshot>(
      endpointId: 'home',
      parseData: HomeSnapshot.fromValue,
    ),
  );

  Future<ApiResult<HomeHotspotViewedReceipt>> markHotspotViewed({
    required String suggestionId,
    required String idempotencyKey,
  }) {
    _validateIdentifier(suggestionId, 'suggestionId');
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError.value(idempotencyKey, 'idempotencyKey');
    }
    return _api.request<HomeHotspotViewedReceipt>(
      ApiRequestOptions<HomeHotspotViewedReceipt>(
        endpointId: 'markHotspotSuggestionViewed',
        pathParams: <String, Object>{'suggestionId': suggestionId},
        body: const <String, Object?>{},
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: HomeHotspotViewedReceipt.fromValue,
      ),
    );
  }
}

Map<String, Object?> _requiredObject(Object? value, String name) {
  final object = asObjectMap(value);
  if (object == null) throw FormatException('$name must be an object');
  return object;
}

List<Object?> _objectList(Object? value, String name) {
  if (value is! List) throw FormatException('$name must be a list');
  return value;
}

String _requiredString(Map<String, Object?> object, String key) {
  final value = _optionalString(object, key);
  if (value == null) throw FormatException('$key must be a non-empty string');
  return value;
}

String? _optionalString(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string when present');
  }
  return value.trim();
}

String _requiredIdentifier(Map<String, Object?> object, String key) {
  final value = _requiredString(object, key);
  _validateIdentifier(value, key);
  return value;
}

String? _optionalIdentifier(Map<String, Object?> object, String key) {
  final value = _optionalString(object, key);
  if (value != null) _validateIdentifier(value, key);
  return value;
}

void _validateIdentifier(String value, String name) {
  if (!_identifierPattern.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'must be an opaque identifier');
  }
}

bool _requiredBool(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

int _requiredCount(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value;
}

num _requiredNumber(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('$key must be a non-negative number');
  }
  return value;
}

DateTime _requiredDate(Map<String, Object?> object, String key) {
  final raw = _requiredString(object, key);
  final value = DateTime.tryParse(raw);
  if (value == null) throw FormatException('$key must be an ISO timestamp');
  return value.toUtc();
}

List<String> _stringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List || value.length > 20) {
    throw const FormatException('Home string list is invalid');
  }
  return List<String>.unmodifiable(
    value.map((item) {
      if (item is! String || item.trim().isEmpty || item.length > 1000) {
        throw const FormatException('Home string list item is invalid');
      }
      return item.trim();
    }),
  );
}

final _identifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$');
