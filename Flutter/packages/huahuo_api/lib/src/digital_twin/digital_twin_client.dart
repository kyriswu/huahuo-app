import 'dart:convert';
import 'dart:typed_data';

import '../api/api_client.dart';
import '../api/idempotency.dart';
import 'digital_twin_models.dart';

final class DigitalTwinScheduleInput {
  const DigitalTwinScheduleInput({
    required this.enabled,
    required this.intervalDays,
    required this.preferredLocalTime,
    required this.timezone,
    required this.instruction,
  });

  final bool enabled;
  final int intervalDays;
  final String preferredLocalTime;
  final String timezone;
  final String instruction;
}

final class DigitalTwinConfirmationProposalInput {
  const DigitalTwinConfirmationProposalInput({
    required this.proposalId,
    required this.proposalVersion,
    required this.etag,
  });

  final String proposalId;
  final int proposalVersion;
  final String etag;
}

final class DigitalTwinClient {
  const DigitalTwinClient(this._api);

  final ApiClient _api;

  Future<ApiResult<DigitalTwinCurrentDto>> current(String workspaceId) {
    final workspace = _id(workspaceId, 'workspaceId');
    return _api.request<DigitalTwinCurrentDto>(
      ApiRequestOptions<DigitalTwinCurrentDto>(
        endpointId: 'digitalTwin',
        pathParams: {'workspaceId': workspace},
        parseData: (value) => DigitalTwinCurrentDto.fromValue(
          value,
          expectedWorkspaceId: workspace,
        ),
      ),
    );
  }

  Future<ApiResult<DigitalTwinScheduleDto>> schedule(String workspaceId) =>
      _read(
        'digitalTwinSchedule',
        workspaceId,
        DigitalTwinScheduleDto.fromValue,
      );

  Future<ApiResult<DigitalTwinScheduleDto>> updateSchedule(
    String workspaceId,
    DigitalTwinScheduleInput input, {
    required String idempotencyKey,
  }) {
    final instruction = input.instruction.trim();
    final time = input.preferredLocalTime.trim();
    final timezone = input.timezone.trim();
    if (input.intervalDays < 1 ||
        input.intervalDays > 365 ||
        utf8.encode(instruction).isEmpty ||
        utf8.encode(instruction).length > 4000 ||
        !RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(time) ||
        !_validTimezone(timezone)) {
      throw ArgumentError('Invalid Digital Twin schedule');
    }
    return _api.request<DigitalTwinScheduleDto>(
      ApiRequestOptions<DigitalTwinScheduleDto>(
        endpointId: 'putDigitalTwinSchedule',
        pathParams: _workspace(workspaceId),
        body: <String, Object>{
          'enabled': input.enabled,
          'intervalDays': input.intervalDays,
          'preferredLocalTime': time,
          'timezone': timezone,
          'instruction': instruction,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: _key(idempotencyKey),
        ),
        parseData: DigitalTwinScheduleDto.fromValue,
      ),
    );
  }

  Future<ApiResult<DigitalTwinConfirmationDto>> createConfirmation(
    String workspaceId,
    List<DigitalTwinConfirmationProposalInput> proposals, {
    required String idempotencyKey,
  }) {
    final workspace = _id(workspaceId, 'workspaceId');
    if (proposals.isEmpty || proposals.length > 20) {
      throw ArgumentError('Invalid Digital Twin confirmation selection');
    }
    final ids = <String>{};
    final body = <Object>[];
    for (final proposal in proposals) {
      final id = _id(proposal.proposalId, 'proposalId');
      if (!ids.add(id) || proposal.proposalVersion < 1) {
        throw ArgumentError('Invalid Digital Twin confirmation Proposal');
      }
      body.add(<String, Object>{
        'proposalId': id,
        'proposalVersion': proposal.proposalVersion,
        'etag': _etag(proposal.etag, id),
      });
    }
    return _api.request<DigitalTwinConfirmationDto>(
      ApiRequestOptions<DigitalTwinConfirmationDto>(
        endpointId: 'createDigitalTwinConfirmation',
        pathParams: {'workspaceId': workspace},
        body: <String, Object>{'proposals': body},
        idempotency: IdempotencyRequestContext(
          explicitKey: _key(idempotencyKey),
        ),
        parseData: (value) => DigitalTwinConfirmationDto.fromValue(
          value,
          expectedWorkspaceId: workspace,
        ),
      ),
    );
  }

  Future<ApiResult<DigitalTwinConfirmationDto>> confirmation(
    String workspaceId,
    String confirmationTaskId,
  ) {
    final workspace = _id(workspaceId, 'workspaceId');
    return _api.request<DigitalTwinConfirmationDto>(
      ApiRequestOptions<DigitalTwinConfirmationDto>(
        endpointId: 'digitalTwinConfirmation',
        pathParams: {
          'workspaceId': workspace,
          'confirmationTaskId': _id(confirmationTaskId, 'confirmationTaskId'),
        },
        parseData: (value) => DigitalTwinConfirmationDto.fromValue(
          value,
          expectedWorkspaceId: workspace,
        ),
      ),
    );
  }

  Future<ApiResult<List<DigitalTwinVersionDto>>> versions(String workspaceId) =>
      _read('digitalTwinVersions', workspaceId, (value) {
        final json = value is Map<String, Object?> ? value : null;
        final raw = json?['items'];
        if (json == null || raw is! List<Object?> || raw.length > 100) {
          throw const FormatException('Invalid Digital Twin versions');
        }
        return List.unmodifiable(raw.map(DigitalTwinVersionDto.fromValue));
      });

  Future<ApiResult<DigitalTwinVersionDetailDto>> version(
    String workspaceId,
    String versionId,
  ) => _read(
    'digitalTwinVersion',
    workspaceId,
    DigitalTwinVersionDetailDto.fromValue,
    versionId: versionId,
  );

  Future<ApiResult<List<DigitalTwinFileDto>>> preview(
    String workspaceId,
    String versionId,
  ) => _read('digitalTwinVersionPreview', workspaceId, (value) {
    final json = value is Map<String, Object?> ? value : null;
    final raw = json?['files'];
    if (json == null || raw is! List<Object?> || raw.length > 100) {
      throw const FormatException('Invalid Digital Twin preview');
    }
    return List.unmodifiable(raw.map(DigitalTwinFileDto.fromValue));
  }, versionId: versionId);

  Future<ApiResult<DigitalTwinComparisonDto>> compare(
    String workspaceId, {
    required String baseVersionId,
    required String versionId,
  }) => _api.request<DigitalTwinComparisonDto>(
    ApiRequestOptions<DigitalTwinComparisonDto>(
      endpointId: 'digitalTwinVersionCompare',
      pathParams: {
        ..._workspace(workspaceId),
        'versionId': _id(versionId, 'versionId'),
      },
      query: {'baseVersionId': _id(baseVersionId, 'baseVersionId')},
      parseData: DigitalTwinComparisonDto.fromValue,
    ),
  );

  Future<ApiResult<DigitalTwinArchiveDto>> download(
    String workspaceId,
    String versionId,
  ) => _api.request<DigitalTwinArchiveDto>(
    ApiRequestOptions<DigitalTwinArchiveDto>(
      endpointId: 'downloadDigitalTwinVersion',
      pathParams: {
        ..._workspace(workspaceId),
        'versionId': _id(versionId, 'versionId'),
      },
      parseData: (value) {
        if (value is! Uint8List ||
            value.length < 4 ||
            value[0] != 0x50 ||
            value[1] != 0x4b) {
          throw const FormatException('Invalid Digital Twin ZIP archive');
        }
        return DigitalTwinArchiveDto(value);
      },
    ),
  );

  Future<ApiResult<DigitalTwinRestoreDto>> restore(
    String workspaceId,
    String versionId, {
    required String idempotencyKey,
  }) => _api.request<DigitalTwinRestoreDto>(
    ApiRequestOptions<DigitalTwinRestoreDto>(
      endpointId: 'restoreDigitalTwinVersion',
      pathParams: {
        ..._workspace(workspaceId),
        'versionId': _id(versionId, 'versionId'),
      },
      body: const <String, Object>{},
      idempotency: IdempotencyRequestContext(explicitKey: _key(idempotencyKey)),
      parseData: (value) {
        final restore = DigitalTwinRestoreDto.fromValue(value);
        if (restore.versionId != versionId) {
          throw const FormatException('Invalid Digital Twin restore identity');
        }
        return restore;
      },
    ),
  );

  Future<ApiResult<T>> _read<T>(
    String endpointId,
    String workspaceId,
    T Function(Object?) parser, {
    String? versionId,
  }) => _api.request<T>(
    ApiRequestOptions<T>(
      endpointId: endpointId,
      pathParams: {
        ..._workspace(workspaceId),
        if (versionId != null) 'versionId': _id(versionId, 'versionId'),
      },
      parseData: parser,
    ),
  );
}

Map<String, Object> _workspace(String workspaceId) => {
  'workspaceId': _id(workspaceId, 'workspaceId'),
};

String _id(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 512 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _key(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 512) {
    throw ArgumentError.value(value, 'idempotencyKey');
  }
  return normalized;
}

String _etag(String value, String proposalId) {
  final normalized = value.trim();
  if (!RegExp(
    '^"dcp:${RegExp.escape(proposalId)}:[1-9][0-9]*"\$',
  ).hasMatch(normalized)) {
    throw ArgumentError.value(value, 'etag');
  }
  return normalized;
}

bool _validTimezone(String value) =>
    value == 'UTC' ||
    RegExp(r'^[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+$').hasMatch(value);
