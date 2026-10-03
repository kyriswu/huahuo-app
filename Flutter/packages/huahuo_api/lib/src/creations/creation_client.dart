import '../api/api_client.dart';
import '../api/idempotency.dart';
import '../contracts/contract_models.dart';

final class CreationPartHeadDto {
  const CreationPartHeadDto({
    required this.part,
    required this.currentRevisionId,
    required this.revision,
    required this.status,
  });

  factory CreationPartHeadDto.fromValue(Object? value) {
    final json = _object(value, 'Creation part');
    _only(json, const {'part', 'currentRevisionId', 'revision', 'status'});
    final part = _part(json['part']);
    final status = _string(json, 'status');
    if (!const {'current', 'trashed'}.contains(status)) {
      throw const FormatException('Invalid Creation part status');
    }
    return CreationPartHeadDto(
      part: part,
      currentRevisionId: _id(json, 'currentRevisionId'),
      revision: _positiveInt(json, 'revision'),
      status: status,
    );
  }

  final String part;
  final String currentRevisionId;
  final int revision;
  final String status;
}

final class CreationDto {
  CreationDto({
    required this.creationId,
    required this.title,
    required this.lifecycle,
    required this.revisionId,
    required this.revision,
    required Iterable<CreationPartHeadDto> parts,
    required this.etag,
  }) : parts = List.unmodifiable(parts);

  factory CreationDto.fromValue(Object? value, {String? expectedId}) {
    final json = _object(value, 'Creation');
    _only(json, const {
      'creationId',
      'title',
      'lifecycle',
      'revisionId',
      'revision',
      'parts',
      'resourceRefs',
      'etag',
    });
    final creationId = _id(json, 'creationId');
    if (expectedId != null && creationId != expectedId) {
      throw const FormatException('Creation identity mismatch');
    }
    final lifecycle = _string(json, 'lifecycle');
    if (!const {'active', 'trashed'}.contains(lifecycle)) {
      throw const FormatException('Invalid Creation lifecycle');
    }
    final rawParts = json['parts'];
    if (rawParts is! List<Object?> || rawParts.length != 3) {
      throw const FormatException('Invalid Creation parts');
    }
    final parts = rawParts.map(CreationPartHeadDto.fromValue).toList();
    if (parts.map((item) => item.part).toSet().length != 3) {
      throw const FormatException('Duplicate Creation parts');
    }
    final resourceRefs = json['resourceRefs'];
    if (resourceRefs is! List<Object?>) {
      throw const FormatException('Invalid Creation resource refs');
    }
    final etag = _etag(json, 'etag');
    return CreationDto(
      creationId: creationId,
      title: _boundedText(json, 'title', 300),
      lifecycle: lifecycle,
      revisionId: _id(json, 'revisionId'),
      revision: _positiveInt(json, 'revision'),
      parts: parts,
      etag: etag,
    );
  }

  final String creationId;
  final String title;
  final String lifecycle;
  final String revisionId;
  final int revision;
  final List<CreationPartHeadDto> parts;
  final String etag;

  CreationPartHeadDto part(String name) =>
      parts.singleWhere((item) => item.part == name);
}

final class CreationPageDto {
  CreationPageDto(Iterable<CreationDto> items)
    : items = List.unmodifiable(items);

  factory CreationPageDto.fromValue(Object? value) {
    final json = _object(value, 'Creation page');
    _only(json, const {'items'});
    final raw = json['items'];
    if (raw is! List<Object?> || raw.length > 500) {
      throw const FormatException('Invalid Creation page');
    }
    final items = raw.map(CreationDto.fromValue).toList();
    if (items.map((item) => item.creationId).toSet().length != items.length) {
      throw const FormatException('Duplicate Creation identity');
    }
    return CreationPageDto(items);
  }

  final List<CreationDto> items;
}

final class CreationPartRevisionDto {
  const CreationPartRevisionDto({
    required this.part,
    required this.partRevisionId,
    required this.revision,
    required this.contentMarkdown,
    required this.contentHash,
    required this.sizeBytes,
    required this.createdAt,
    required this.etag,
    this.previousPartRevisionId,
  });

  factory CreationPartRevisionDto.fromValue(
    Object? value, {
    String? expectedPart,
    String? expectedRevisionId,
  }) {
    final json = _object(value, 'Creation part revision');
    _only(json, const {
      'part',
      'partRevisionId',
      'revision',
      'previousPartRevisionId',
      'contentMarkdown',
      'contentHash',
      'sizeBytes',
      'sourceRefs',
      'createdAt',
      'etag',
    });
    final part = _part(json['part']);
    final revisionId = _id(json, 'partRevisionId');
    if ((expectedPart != null && part != expectedPart) ||
        (expectedRevisionId != null && revisionId != expectedRevisionId)) {
      throw const FormatException('Creation part identity mismatch');
    }
    if (json['sourceRefs'] is! List<Object?>) {
      throw const FormatException('Invalid Creation part sources');
    }
    return CreationPartRevisionDto(
      part: part,
      partRevisionId: revisionId,
      revision: _positiveInt(json, 'revision'),
      previousPartRevisionId: _optionalId(
        json['previousPartRevisionId'],
        'previousPartRevisionId',
      ),
      contentMarkdown: _markdown(json['contentMarkdown']),
      contentHash: _hash(json, 'contentHash'),
      sizeBytes: _nonNegativeInt(json, 'sizeBytes'),
      createdAt: _date(json, 'createdAt'),
      etag: _etag(json, 'etag'),
    );
  }

  final String part;
  final String partRevisionId;
  final int revision;
  final String? previousPartRevisionId;
  final String contentMarkdown;
  final String contentHash;
  final int sizeBytes;
  final DateTime createdAt;
  final String etag;
}

final class CreationRevisionPageDto {
  CreationRevisionPageDto(Iterable<CreationPartRevisionDto> items)
    : items = List.unmodifiable(items);

  factory CreationRevisionPageDto.fromValue(
    Object? value, {
    required String expectedPart,
  }) {
    final json = _object(value, 'Creation revision page');
    _only(json, const {'items'});
    final raw = json['items'];
    if (raw is! List<Object?> || raw.length > 500) {
      throw const FormatException('Invalid Creation revision page');
    }
    final items = raw
        .map(
          (item) => CreationPartRevisionDto.fromValue(
            item,
            expectedPart: expectedPart,
          ),
        )
        .toList();
    return CreationRevisionPageDto(items);
  }

  final List<CreationPartRevisionDto> items;
}

final class CreationClient {
  const CreationClient(this._api);

  final ApiClient _api;

  Future<ApiResult<CreationPageDto>> list(String workspaceId) =>
      _api.request<CreationPageDto>(
        ApiRequestOptions<CreationPageDto>(
          endpointId: 'workspaceCreations',
          pathParams: _workspacePath(workspaceId),
          parseData: CreationPageDto.fromValue,
        ),
      );

  Future<ApiResult<CreationDto>> detail(String workspaceId, String creationId) {
    final id = _safeId(creationId, 'creationId');
    return _api.request<CreationDto>(
      ApiRequestOptions<CreationDto>(
        endpointId: 'workspaceCreationDetail',
        pathParams: {..._workspacePath(workspaceId), 'creationId': id},
        parseData: (value) => CreationDto.fromValue(value, expectedId: id),
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> create(
    String workspaceId, {
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'createWorkspaceCreation',
    workspaceId: workspaceId,
    body: <String, Object?>{
      'title': _inputText(title, 'title', 300),
      'parts': <String, Object?>{
        'raw': _inputMarkdown(rawMarkdown),
        'outline': '',
        'germination': '',
      },
      'sourceRefs': const <Object?>[],
      'resourceRefs': const <Object?>[],
    },
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> rename(
    String workspaceId,
    String creationId, {
    required String title,
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'updateWorkspaceCreation',
    workspaceId: workspaceId,
    creationId: creationId,
    body: <String, Object?>{'title': _inputText(title, 'title', 300)},
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> restore(
    String workspaceId,
    String creationId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'restoreWorkspaceCreation',
    workspaceId: workspaceId,
    creationId: creationId,
    body: const <String, Object?>{},
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<bool>> delete(
    String workspaceId,
    String creationId, {
    required String etag,
    required String idempotencyKey,
  }) => _api.request<bool>(
    ApiRequestOptions<bool>(
      endpointId: 'deleteWorkspaceCreation',
      pathParams: {
        ..._workspacePath(workspaceId),
        'creationId': _safeId(creationId, 'creationId'),
      },
      headers: {'If-Match': _strongEtag(etag)},
      idempotency: IdempotencyRequestContext(
        explicitKey: _safeIdempotency(idempotencyKey),
      ),
      parseData: (value) {
        if (value == null) return true;
        final event = _event(value, workspaceId, creationId);
        return event.tombstone;
      },
    ),
  );

  Future<ApiResult<CreationPartRevisionDto>> part(
    String workspaceId,
    String creationId,
    String part,
  ) {
    final id = _safeId(creationId, 'creationId');
    final normalizedPart = _part(part);
    return _api.request<CreationPartRevisionDto>(
      ApiRequestOptions<CreationPartRevisionDto>(
        endpointId: 'workspaceCreationPart',
        pathParams: {
          ..._workspacePath(workspaceId),
          'creationId': id,
          'part': normalizedPart,
        },
        parseData: (value) => CreationPartRevisionDto.fromValue(
          value,
          expectedPart: normalizedPart,
        ),
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> putPart(
    String workspaceId,
    String creationId,
    String part, {
    required String contentMarkdown,
    required String basePartRevisionId,
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'putWorkspaceCreationPart',
    workspaceId: workspaceId,
    creationId: creationId,
    part: _part(part),
    body: <String, Object?>{
      'contentMarkdown': _inputMarkdown(contentMarkdown),
      'basePartRevisionId': _safeId(basePartRevisionId, 'basePartRevisionId'),
      'sourceRefs': const <Object?>[],
      'resourceRefs': const <Object?>[],
    },
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<CreationRevisionPageDto>> revisions(
    String workspaceId,
    String creationId,
    String part,
  ) {
    final normalizedPart = _part(part);
    return _api.request<CreationRevisionPageDto>(
      ApiRequestOptions<CreationRevisionPageDto>(
        endpointId: 'workspaceCreationPartRevisions',
        pathParams: {
          ..._workspacePath(workspaceId),
          'creationId': _safeId(creationId, 'creationId'),
          'part': normalizedPart,
        },
        parseData: (value) => CreationRevisionPageDto.fromValue(
          value,
          expectedPart: normalizedPart,
        ),
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> _mutation({
    required String endpointId,
    required String workspaceId,
    String? creationId,
    String? part,
    Object? body,
    String? etag,
    required String idempotencyKey,
  }) {
    final normalizedWorkspaceId = _safeId(workspaceId, 'workspaceId');
    final normalizedCreationId = creationId == null
        ? null
        : _safeId(creationId, 'creationId');
    return _api.request<SharedWorkspaceContentEvent>(
      ApiRequestOptions<SharedWorkspaceContentEvent>(
        endpointId: endpointId,
        pathParams: <String, Object>{
          'workspaceId': normalizedWorkspaceId,
          if (normalizedCreationId != null) 'creationId': normalizedCreationId,
          if (part != null) 'part': part,
        },
        headers: etag == null
            ? const <String, String>{}
            : <String, String>{'If-Match': _strongEtag(etag)},
        body: body,
        idempotency: IdempotencyRequestContext(
          explicitKey: _safeIdempotency(idempotencyKey),
        ),
        parseData: (value) =>
            _event(value, normalizedWorkspaceId, normalizedCreationId),
      ),
    );
  }
}

Map<String, Object> _workspacePath(String workspaceId) => <String, Object>{
  'workspaceId': _safeId(workspaceId, 'workspaceId'),
};

SharedWorkspaceContentEvent _event(
  Object? value,
  String workspaceId,
  String? creationId,
) {
  final event = SharedWorkspaceContentEvent.fromJson(
    _object(value, 'Creation mutation receipt'),
  );
  if (event.workspaceId != workspaceId ||
      event.objectKind != 'creation' ||
      (creationId != null && event.objectId != creationId) ||
      event.revisionId == null ||
      event.version != null) {
    throw const FormatException('Invalid Creation mutation receipt');
  }
  return event;
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) throw FormatException('Invalid $label');
  return value;
}

void _only(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unexpected Creation field');
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $key');
  }
  return value.trim();
}

String _boundedText(Map<String, Object?> json, String key, int max) {
  final value = _string(json, key);
  if (value.length > max) throw FormatException('Invalid $key');
  return value;
}

String _id(Map<String, Object?> json, String key) =>
    _safeId(_string(json, key), key);

String? _optionalId(Object? value, String key) {
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key');
  return _safeId(value, key);
}

String _safeId(String value, String key) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 200 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(value, key, 'invalid identifier');
  }
  return normalized;
}

String _part(Object? value) {
  if (value is! String ||
      !const {'raw', 'outline', 'germination'}.contains(value)) {
    throw const FormatException('Invalid Creation part');
  }
  return value;
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 1) throw FormatException('Invalid $key');
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

DateTime _date(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key');
  final parsed = DateTime.tryParse(value)?.toUtc();
  if (parsed == null) throw FormatException('Invalid $key');
  return parsed;
}

String _hash(Map<String, Object?> json, String key) {
  final value = _string(json, key).toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _etag(Map<String, Object?> json, String key) =>
    _strongEtag(_string(json, key));

String _strongEtag(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^"wcc-[a-f0-9]{64}"$').hasMatch(normalized)) {
    throw const FormatException('Invalid Creation ETag');
  }
  return normalized;
}

String _markdown(Object? value) {
  if (value is! String || value.length > 2 * 1024 * 1024) {
    throw const FormatException('Invalid Creation Markdown');
  }
  return value;
}

String _inputText(String value, String name, int max) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > max) {
    throw ArgumentError.value(value, name, 'invalid text');
  }
  return normalized;
}

String _inputMarkdown(String value) {
  if (value.length > 2 * 1024 * 1024) {
    throw ArgumentError.value(value, 'contentMarkdown', 'content too large');
  }
  return value;
}

String _safeIdempotency(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(value, 'idempotencyKey', 'invalid key');
  }
  return normalized;
}
