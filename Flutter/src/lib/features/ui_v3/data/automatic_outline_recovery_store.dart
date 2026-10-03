import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_preferences_dao.dart';
import 'note_file_agent_client.dart';

const _automaticOutlineTerminalStatuses = <String>{
  'succeeded',
  'failed',
  'timeout',
  'conflict',
  'cancelled',
  'orphaned',
};

const _automaticOutlineAcceptedStatuses = <String>{
  'admitting',
  'retry_wait',
  'retry_admitting',
  'queued',
  'resolving',
  'planning',
  'running',
  'finalizing',
  'succeeded',
  'failed',
  'timeout',
  'conflict',
  'cancelled',
};

bool isAutomaticOutlineOperationId(String? value) =>
    value?.startsWith('auto-outline-v1-') == true ||
    value?.startsWith('media-outline:ingestion_') == true;

String? automaticOutlineRequestIdempotencyKey(
  String? operationId, {
  int backendAdmissionAttempt = 0,
}) {
  final operation = _journalText(operationId, maximumLength: 256);
  if (!isAutomaticOutlineOperationId(operation) ||
      backendAdmissionAttempt < 0 ||
      backendAdmissionAttempt > 10000) {
    return null;
  }
  if (backendAdmissionAttempt > 0) {
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode(<Object>[
          'automatic-outline-backend-admission-v1',
          operation!,
          backendAdmissionAttempt,
        ]),
      ),
    );
    return 'outline-retry-v1-$digest';
  }
  return operation!.startsWith('media-outline:ingestion_')
      ? operation
      : 'detail-outline-$operation';
}

String automaticOutlineAttemptId({
  required String workspaceScope,
  required String remoteNoteId,
  required String inputRawRevisionId,
  required String? targetOutlineRevisionId,
}) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<String>[
          'auto-outline-v1',
          workspaceScope,
          remoteNoteId,
          inputRawRevisionId,
          targetOutlineRevisionId ?? '',
        ]),
      ),
    )
    .toString();

@immutable
final class AutomaticOutlinePreparedAdmission {
  const AutomaticOutlinePreparedAdmission({
    required this.attemptId,
    required this.localNoteId,
    required this.operationId,
    required this.request,
    required this.allowExistingAutomaticOutline,
    required this.createdAt,
    this.backendAdmissionAttempt = 0,
    this.accepted,
  });

  final String attemptId;
  final String localNoteId;
  final String operationId;
  final NoteFileAgentRequest request;
  final bool allowExistingAutomaticOutline;
  final DateTime createdAt;
  final int backendAdmissionAttempt;
  final NoteFileAgentRunSnapshot? accepted;

  String get remoteNoteId => request.noteId;
  String get inputRawRevisionId => request.inputPartRevisionId;
  String get targetOutlineRevisionId => request.targetPartRevisionId;

  AutomaticOutlinePreparedAdmission? withAccepted(
    NoteFileAgentRunSnapshot value,
  ) {
    if (value.noteId != remoteNoteId ||
        value.inputPart != NoteFileAgentPart.raw ||
        value.inputPartRevisionId != inputRawRevisionId ||
        value.targetPart != NoteFileAgentPart.outline ||
        value.targetPartRevisionId != targetOutlineRevisionId) {
      return null;
    }
    return AutomaticOutlinePreparedAdmission(
      attemptId: attemptId,
      localNoteId: localNoteId,
      operationId: operationId,
      request: request,
      allowExistingAutomaticOutline: allowExistingAutomaticOutline,
      createdAt: createdAt,
      backendAdmissionAttempt: backendAdmissionAttempt,
      accepted: value,
    );
  }
}

@immutable
final class AutomaticOutlineTerminalRecord {
  const AutomaticOutlineTerminalRecord({
    required this.attemptId,
    required this.remoteNoteId,
    required this.operationId,
    required this.inputRawRevisionId,
    required this.targetOutlineRevisionId,
    required this.status,
    required this.recordedAt,
    this.fileAgentRunId,
    this.outputOutlineRevisionId,
  });

  final String attemptId;
  final String remoteNoteId;
  final String operationId;
  final String inputRawRevisionId;
  final String targetOutlineRevisionId;
  final String status;
  final String? fileAgentRunId;
  final String? outputOutlineRevisionId;
  final DateTime recordedAt;

  bool get isSucceeded => status == 'succeeded';
}

abstract interface class AutomaticOutlineRecoveryStorePort {
  String get workspaceScope;

  bool canReadRemoteNote(String remoteNoteId);

  AutomaticOutlinePreparedAdmission? admissionForRemoteNote(
    String remoteNoteId,
  );

  List<AutomaticOutlineTerminalRecord> terminalAttemptsForRemoteNote(
    String remoteNoteId,
  );

  Future<bool> putPrepared(AutomaticOutlinePreparedAdmission admission);

  Future<bool> replacePrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlinePreparedAdmission replacement,
  });

  Future<bool> promoteAccepted({
    required AutomaticOutlinePreparedAdmission admission,
    required NoteFileAgentRunSnapshot accepted,
  });

  Future<bool> removeAccepted({
    required String remoteNoteId,
    required String attemptId,
    required String fileAgentRunId,
  });

  Future<bool> failPrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlineTerminalRecord terminal,
  });

  Future<bool> putTerminal(AutomaticOutlineTerminalRecord terminal);
}

final class InMemoryAutomaticOutlineRecoveryStore
    implements AutomaticOutlineRecoveryStorePort {
  InMemoryAutomaticOutlineRecoveryStore({this.workspaceScope = 'workspace-1'});

  @override
  final String workspaceScope;

  final Map<String, _AutomaticOutlineAssetRecovery> _records =
      <String, _AutomaticOutlineAssetRecovery>{};

  @override
  bool canReadRemoteNote(String remoteNoteId) =>
      _journalText(remoteNoteId, maximumLength: 512) != null;

  @override
  AutomaticOutlinePreparedAdmission? admissionForRemoteNote(
    String remoteNoteId,
  ) => _records[_normalizedRemoteNoteId(remoteNoteId)]?.active;

  @override
  List<AutomaticOutlineTerminalRecord> terminalAttemptsForRemoteNote(
    String remoteNoteId,
  ) => List<AutomaticOutlineTerminalRecord>.unmodifiable(
    _records[_normalizedRemoteNoteId(remoteNoteId)]?.terminals ??
        const <AutomaticOutlineTerminalRecord>[],
  );

  @override
  Future<bool> putPrepared(AutomaticOutlinePreparedAdmission admission) async {
    if (admission.accepted != null ||
        !_preparedMatchesWorkspace(admission, workspaceScope)) {
      return false;
    }
    final next = _recordWithPrepared(
      _records[admission.remoteNoteId] ??
          const _AutomaticOutlineAssetRecovery(),
      admission,
    );
    if (next == null) return false;
    _records[admission.remoteNoteId] = next;
    return true;
  }

  @override
  Future<bool> replacePrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlinePreparedAdmission replacement,
  }) async {
    if (!_preparedMatchesWorkspace(expected, workspaceScope) ||
        !_preparedMatchesWorkspace(replacement, workspaceScope)) {
      return false;
    }
    final remoteNoteId = _normalizedRemoteNoteId(expected.remoteNoteId);
    if (remoteNoteId == null || remoteNoteId != replacement.remoteNoteId) {
      return false;
    }
    final next = _recordWithPreparedReplacement(
      _records[remoteNoteId] ?? const _AutomaticOutlineAssetRecovery(),
      expected,
      replacement,
    );
    if (next == null) return false;
    _records[remoteNoteId] = next;
    return true;
  }

  @override
  Future<bool> promoteAccepted({
    required AutomaticOutlinePreparedAdmission admission,
    required NoteFileAgentRunSnapshot accepted,
  }) async {
    if (!_preparedMatchesWorkspace(admission, workspaceScope)) return false;
    final next = _recordWithAccepted(
      _records[admission.remoteNoteId] ??
          const _AutomaticOutlineAssetRecovery(),
      admission,
      accepted,
    );
    if (next == null) return false;
    _records[admission.remoteNoteId] = next;
    return true;
  }

  @override
  Future<bool> removeAccepted({
    required String remoteNoteId,
    required String attemptId,
    required String fileAgentRunId,
  }) async {
    final remote = _normalizedRemoteNoteId(remoteNoteId);
    if (remote == null) return false;
    final next = _recordWithoutAccepted(
      _records[remote] ?? const _AutomaticOutlineAssetRecovery(),
      attemptId: attemptId,
      fileAgentRunId: fileAgentRunId,
    );
    if (next == null) return false;
    _records[remote] = next;
    return true;
  }

  @override
  Future<bool> failPrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlineTerminalRecord terminal,
  }) async {
    if (!_preparedMatchesWorkspace(expected, workspaceScope) ||
        !_terminalMatchesWorkspace(terminal, workspaceScope)) {
      return false;
    }
    final remoteNoteId = _normalizedRemoteNoteId(expected.remoteNoteId);
    if (remoteNoteId == null || remoteNoteId != terminal.remoteNoteId) {
      return false;
    }
    final next = _recordWithPreparedFailure(
      _records[remoteNoteId] ?? const _AutomaticOutlineAssetRecovery(),
      expected,
      terminal,
    );
    if (next == null) return false;
    _records[remoteNoteId] = next;
    return true;
  }

  @override
  Future<bool> putTerminal(AutomaticOutlineTerminalRecord terminal) async {
    if (!_terminalMatchesWorkspace(terminal, workspaceScope)) return false;
    final next = _recordWithTerminal(
      _records[terminal.remoteNoteId] ?? const _AutomaticOutlineAssetRecovery(),
      terminal,
    );
    if (next == null) return false;
    _records[terminal.remoteNoteId] = next;
    return true;
  }
}

final class AutomaticOutlineRecoveryStoreRegistry {
  AutomaticOutlineRecoveryStoreRegistry(this._preferences);

  final AppPreferencesDao _preferences;
  final Map<String, AutomaticOutlineRecoveryStorePort> _stores =
      <String, AutomaticOutlineRecoveryStorePort>{};

  AutomaticOutlineRecoveryStorePort scoped({
    required String accountScope,
    required String workspaceScope,
  }) {
    final account = _requiredScope(accountScope, 'accountScope');
    final workspace = _requiredScope(workspaceScope, 'workspaceScope');
    final scopeDigest = sha256
        .convert(utf8.encode(jsonEncode(<String>[account, workspace])))
        .toString();
    return _stores.putIfAbsent(
      scopeDigest,
      () => _PersistentAutomaticOutlineRecoveryStore(
        preferences: _preferences,
        scopeDigest: scopeDigest,
        workspaceScope: workspace,
      ),
    );
  }
}

final class _PersistentAutomaticOutlineRecoveryStore
    implements AutomaticOutlineRecoveryStorePort {
  _PersistentAutomaticOutlineRecoveryStore({
    required this._preferences,
    required this.scopeDigest,
    required this.workspaceScope,
  });

  final AppPreferencesDao _preferences;
  final String scopeDigest;
  @override
  final String workspaceScope;
  final Map<String, _AutomaticOutlineAssetRecovery> _committed =
      <String, _AutomaticOutlineAssetRecovery>{};
  final Set<String> _loaded = <String>{};
  final Set<String> _unreadable = <String>{};
  Future<void> _writeTail = Future<void>.value();

  @override
  bool canReadRemoteNote(String remoteNoteId) {
    try {
      _readCommitted(remoteNoteId);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  AutomaticOutlinePreparedAdmission? admissionForRemoteNote(
    String remoteNoteId,
  ) {
    try {
      return _readCommitted(remoteNoteId).active;
    } on Object {
      return null;
    }
  }

  @override
  List<AutomaticOutlineTerminalRecord> terminalAttemptsForRemoteNote(
    String remoteNoteId,
  ) {
    try {
      return List<AutomaticOutlineTerminalRecord>.unmodifiable(
        _readCommitted(remoteNoteId).terminals,
      );
    } on Object {
      return const <AutomaticOutlineTerminalRecord>[];
    }
  }

  @override
  Future<bool> putPrepared(AutomaticOutlinePreparedAdmission admission) =>
      admission.accepted != null ||
          !_preparedMatchesWorkspace(admission, workspaceScope)
      ? Future<bool>.value(false)
      : _mutate(
          admission.remoteNoteId,
          (current) => _recordWithPrepared(current, admission),
        );

  @override
  Future<bool> replacePrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlinePreparedAdmission replacement,
  }) => _mutate(
    expected.remoteNoteId,
    (current) =>
        _preparedMatchesWorkspace(expected, workspaceScope) &&
            _preparedMatchesWorkspace(replacement, workspaceScope) &&
            expected.remoteNoteId == replacement.remoteNoteId
        ? _recordWithPreparedReplacement(current, expected, replacement)
        : null,
  );

  @override
  Future<bool> promoteAccepted({
    required AutomaticOutlinePreparedAdmission admission,
    required NoteFileAgentRunSnapshot accepted,
  }) => _mutate(
    admission.remoteNoteId,
    (current) => _preparedMatchesWorkspace(admission, workspaceScope)
        ? _recordWithAccepted(current, admission, accepted)
        : null,
  );

  @override
  Future<bool> removeAccepted({
    required String remoteNoteId,
    required String attemptId,
    required String fileAgentRunId,
  }) => _mutate(
    remoteNoteId,
    (current) => _recordWithoutAccepted(
      current,
      attemptId: attemptId,
      fileAgentRunId: fileAgentRunId,
    ),
  );

  @override
  Future<bool> failPrepared({
    required AutomaticOutlinePreparedAdmission expected,
    required AutomaticOutlineTerminalRecord terminal,
  }) => _mutate(
    expected.remoteNoteId,
    (current) =>
        _preparedMatchesWorkspace(expected, workspaceScope) &&
            _terminalMatchesWorkspace(terminal, workspaceScope) &&
            expected.remoteNoteId == terminal.remoteNoteId
        ? _recordWithPreparedFailure(current, expected, terminal)
        : null,
  );

  @override
  Future<bool> putTerminal(AutomaticOutlineTerminalRecord terminal) => _mutate(
    terminal.remoteNoteId,
    (current) => _terminalMatchesWorkspace(terminal, workspaceScope)
        ? _recordWithTerminal(current, terminal)
        : null,
  );

  Future<bool> _mutate(
    String remoteNoteId,
    _AutomaticOutlineAssetRecovery? Function(
      _AutomaticOutlineAssetRecovery current,
    )
    transform,
  ) {
    final result = Completer<bool>();
    final remote = _normalizedRemoteNoteId(remoteNoteId);
    if (remote == null) return Future<bool>.value(false);
    final previous = _writeTail;
    _writeTail = () async {
      try {
        await previous;
      } on Object {
        // Each mutation reports its own failure and must not poison the tail.
      }
      try {
        final current = _readCommitted(remote);
        final next = transform(current);
        if (next == null) {
          result.complete(false);
          return;
        }
        if (_sameRecoveryRecord(current, next)) {
          result.complete(true);
          return;
        }
        final value = jsonEncode(<String, Object?>{
          'schema': 1,
          'scopeDigest': scopeDigest,
          'remoteNoteId': remote,
          'active': next.active == null ? null : _preparedToJson(next.active!),
          'terminals': next.terminals.map(_terminalToJson).toList(),
        });
        await _preferences.upsertValueDeferred(
          preferenceKey: _preferenceKey(remote),
          value: value,
          updatedAt: DateTime.now().toUtc().toIso8601String(),
        );
        _committed[remote] = next;
        result.complete(true);
      } on Object {
        result.complete(false);
      }
    }();
    return result.future;
  }

  _AutomaticOutlineAssetRecovery _readCommitted(String remoteNoteId) {
    final remote = _requiredJournalText(
      remoteNoteId,
      'remoteNoteId',
      maximumLength: 512,
    );
    if (_unreadable.contains(remote)) throw const FormatException();
    if (_loaded.contains(remote)) {
      return _committed[remote] ?? const _AutomaticOutlineAssetRecovery();
    }
    try {
      final raw = _preferences.readValue(_preferenceKey(remote));
      final record = raw == null
          ? const _AutomaticOutlineAssetRecovery()
          : _recoveryRecordFromJson(
              jsonDecode(raw),
              expectedScopeDigest: scopeDigest,
              expectedRemoteNoteId: remote,
            );
      final active = record.active;
      if (active != null &&
          !_preparedMatchesWorkspace(active, workspaceScope)) {
        throw const FormatException();
      }
      if (record.terminals.any(
        (terminal) => !_terminalMatchesWorkspace(terminal, workspaceScope),
      )) {
        throw const FormatException();
      }
      _loaded.add(remote);
      _committed[remote] = record;
      return record;
    } on Object {
      _unreadable.add(remote);
      rethrow;
    }
  }

  String _preferenceKey(String remoteNoteId) =>
      'automatic-outline.v1.${sha256.convert(utf8.encode('$scopeDigest|$remoteNoteId')).toString().substring(0, 48)}';
}

@immutable
final class _AutomaticOutlineAssetRecovery {
  const _AutomaticOutlineAssetRecovery({
    this.active,
    this.terminals = const <AutomaticOutlineTerminalRecord>[],
  });

  final AutomaticOutlinePreparedAdmission? active;
  final List<AutomaticOutlineTerminalRecord> terminals;
}

_AutomaticOutlineAssetRecovery? _recordWithPrepared(
  _AutomaticOutlineAssetRecovery current,
  AutomaticOutlinePreparedAdmission admission,
) {
  if (admission.accepted != null || !_validPreparedAdmission(admission)) {
    return null;
  }
  final active = current.active;
  if (active != null) {
    return _samePreparedRequest(active, admission) ? current : null;
  }
  if (current.terminals.any(
    (terminal) => _sameTerminalLifecycle(terminal, admission),
  )) {
    return null;
  }
  return _AutomaticOutlineAssetRecovery(
    active: admission,
    terminals: current.terminals,
  );
}

_AutomaticOutlineAssetRecovery? _recordWithPreparedReplacement(
  _AutomaticOutlineAssetRecovery current,
  AutomaticOutlinePreparedAdmission expected,
  AutomaticOutlinePreparedAdmission replacement,
) {
  final active = current.active;
  if (active == null ||
      !_samePreparedAdmission(active, expected) ||
      !_validPreparedReplacement(expected, replacement)) {
    return null;
  }
  return _AutomaticOutlineAssetRecovery(
    active: replacement,
    terminals: current.terminals,
  );
}

_AutomaticOutlineAssetRecovery? _recordWithAccepted(
  _AutomaticOutlineAssetRecovery current,
  AutomaticOutlinePreparedAdmission admission,
  NoteFileAgentRunSnapshot accepted,
) {
  if (!_validAcceptedRun(accepted)) return null;
  final active = current.active;
  if (active == null || !_samePreparedRequest(active, admission)) return null;
  final promoted = active.withAccepted(accepted);
  if (promoted == null) return null;
  final existing = active.accepted;
  if (existing != null && !_sameAcceptedRun(existing, accepted)) return null;
  return _AutomaticOutlineAssetRecovery(
    active: promoted,
    terminals: current.terminals,
  );
}

_AutomaticOutlineAssetRecovery? _recordWithoutAccepted(
  _AutomaticOutlineAssetRecovery current, {
  required String attemptId,
  required String fileAgentRunId,
}) {
  final active = current.active;
  if (active == null) return current;
  if (active.attemptId != attemptId ||
      active.accepted?.fileAgentRunId != fileAgentRunId) {
    return null;
  }
  return _AutomaticOutlineAssetRecovery(terminals: current.terminals);
}

_AutomaticOutlineAssetRecovery? _recordWithPreparedFailure(
  _AutomaticOutlineAssetRecovery current,
  AutomaticOutlinePreparedAdmission expected,
  AutomaticOutlineTerminalRecord terminal,
) {
  final active = current.active;
  if (active == null ||
      !_samePreparedAdmission(active, expected) ||
      !_sameTerminalLifecycle(terminal, active) ||
      active.accepted?.fileAgentRunId != terminal.fileAgentRunId) {
    return null;
  }
  return _recordWithTerminal(current, terminal);
}

_AutomaticOutlineAssetRecovery? _recordWithTerminal(
  _AutomaticOutlineAssetRecovery current,
  AutomaticOutlineTerminalRecord terminal,
) {
  if (!_validTerminalRecord(terminal)) return null;
  final active = current.active;
  var retainedActive = active;
  if (active != null &&
      active.attemptId == terminal.attemptId &&
      active.operationId == terminal.operationId) {
    if (!_sameTerminalLifecycle(terminal, active)) return null;
    final acceptedRunId = active.accepted?.fileAgentRunId;
    if (acceptedRunId != null && terminal.fileAgentRunId != acceptedRunId) {
      return null;
    }
    retainedActive = null;
  }
  final existing = current.terminals.where(
    (entry) => _sameTerminalIdentity(entry, terminal),
  );
  var nextTerminal = terminal;
  if (existing.isNotEmpty) {
    final previous = existing.single;
    if (!_sameTerminalResult(previous, terminal)) return null;
    if (!terminal.recordedAt.isAfter(previous.recordedAt)) {
      if (previous.fileAgentRunId != null || terminal.fileAgentRunId == null) {
        return current;
      }
      nextTerminal = _terminalWithFileAgentRunId(
        previous,
        terminal.fileAgentRunId!,
      );
    } else if (terminal.fileAgentRunId == null &&
        previous.fileAgentRunId != null) {
      nextTerminal = _terminalWithFileAgentRunId(
        terminal,
        previous.fileAgentRunId!,
      );
    }
  }
  final terminals = <AutomaticOutlineTerminalRecord>[
    nextTerminal,
    ...current.terminals.where(
      (entry) => !_sameTerminalIdentity(entry, terminal),
    ),
  ]..sort((left, right) => right.recordedAt.compareTo(left.recordedAt));
  return _AutomaticOutlineAssetRecovery(
    active: retainedActive,
    terminals: List<AutomaticOutlineTerminalRecord>.unmodifiable(
      terminals.take(32),
    ),
  );
}

bool _validPreparedAdmission(AutomaticOutlinePreparedAdmission value) =>
    _canonicalJournalText(value.attemptId, maximumLength: 128) &&
    _canonicalJournalText(value.localNoteId, maximumLength: 512) &&
    _canonicalJournalText(value.operationId, maximumLength: 256) &&
    isAutomaticOutlineOperationId(value.operationId) &&
    value.backendAdmissionAttempt >= 0 &&
    value.backendAdmissionAttempt <= 10000 &&
    _validAutomaticOutlineRequest(value.request) &&
    value.request.idempotencyKey ==
        automaticOutlineRequestIdempotencyKey(
          value.operationId,
          backendAdmissionAttempt: value.backendAdmissionAttempt,
        ) &&
    (value.accepted == null ||
        _validAcceptedRun(value.accepted!) &&
            value.withAccepted(value.accepted!) != null);

bool _validTerminalRecord(AutomaticOutlineTerminalRecord value) =>
    _canonicalJournalText(value.attemptId, maximumLength: 128) &&
    _canonicalJournalText(value.remoteNoteId, maximumLength: 512) &&
    _canonicalJournalText(value.operationId, maximumLength: 256) &&
    isAutomaticOutlineOperationId(value.operationId) &&
    _canonicalJournalText(value.inputRawRevisionId, maximumLength: 512) &&
    _canonicalJournalText(value.targetOutlineRevisionId, maximumLength: 512) &&
    _automaticOutlineTerminalStatuses.contains(value.status) &&
    (value.fileAgentRunId == null ||
        _canonicalJournalText(value.fileAgentRunId!, maximumLength: 512)) &&
    (!value.isSucceeded ||
        value.outputOutlineRevisionId != null &&
            _canonicalJournalText(
              value.outputOutlineRevisionId!,
              maximumLength: 512,
            )) &&
    (value.outputOutlineRevisionId == null ||
        _canonicalJournalText(
          value.outputOutlineRevisionId!,
          maximumLength: 512,
        ));

bool _validAutomaticOutlineRequest(NoteFileAgentRequest value) =>
    _canonicalJournalText(value.noteId, maximumLength: 512) &&
    value.inputPart == NoteFileAgentPart.raw &&
    _canonicalJournalText(value.inputPartRevisionId, maximumLength: 512) &&
    value.targetPart == NoteFileAgentPart.outline &&
    _canonicalJournalText(value.targetPartRevisionId, maximumLength: 512) &&
    _canonicalJournalText(value.instruction, maximumLength: 8192) &&
    _canonicalJournalText(value.selector.agentProfileId, maximumLength: 256) &&
    value.selector.skillProfileIds.isNotEmpty &&
    value.selector.skillProfileIds.length <= 32 &&
    value.selector.skillProfileIds.every(
      (skill) => _canonicalJournalText(skill, maximumLength: 256),
    ) &&
    _canonicalJournalText(value.idempotencyKey, maximumLength: 256) &&
    (value.modelProfileId == null ||
        _canonicalJournalText(value.modelProfileId!, maximumLength: 256));

bool _validAcceptedRun(NoteFileAgentRunSnapshot value) =>
    _canonicalJournalText(value.fileAgentRunId, maximumLength: 512) &&
    _canonicalJournalText(value.noteId, maximumLength: 512) &&
    _automaticOutlineAcceptedStatuses.contains(value.status) &&
    _canonicalJournalText(value.agentRunId, maximumLength: 512) &&
    value.inputPart == NoteFileAgentPart.raw &&
    _canonicalJournalText(value.inputPartRevisionId, maximumLength: 512) &&
    value.targetPart == NoteFileAgentPart.outline &&
    _canonicalJournalText(value.targetPartRevisionId, maximumLength: 512) &&
    (value.outputPartRevisionId == null ||
        _canonicalJournalText(
          value.outputPartRevisionId!,
          maximumLength: 512,
        )) &&
    (value.failureCode == null ||
        _canonicalJournalText(value.failureCode!, maximumLength: 256));

bool _preparedMatchesWorkspace(
  AutomaticOutlinePreparedAdmission value,
  String workspaceScope,
) =>
    _validPreparedAdmission(value) &&
    value.attemptId ==
        automaticOutlineAttemptId(
          workspaceScope: workspaceScope,
          remoteNoteId: value.remoteNoteId,
          inputRawRevisionId: value.inputRawRevisionId,
          targetOutlineRevisionId: value.targetOutlineRevisionId,
        );

bool _terminalMatchesWorkspace(
  AutomaticOutlineTerminalRecord value,
  String workspaceScope,
) =>
    _validTerminalRecord(value) &&
    value.attemptId ==
        automaticOutlineAttemptId(
          workspaceScope: workspaceScope,
          remoteNoteId: value.remoteNoteId,
          inputRawRevisionId: value.inputRawRevisionId,
          targetOutlineRevisionId: value.targetOutlineRevisionId,
        );

bool _samePreparedRequest(
  AutomaticOutlinePreparedAdmission left,
  AutomaticOutlinePreparedAdmission right,
) =>
    left.attemptId == right.attemptId &&
    left.localNoteId == right.localNoteId &&
    left.operationId == right.operationId &&
    left.backendAdmissionAttempt == right.backendAdmissionAttempt &&
    left.allowExistingAutomaticOutline == right.allowExistingAutomaticOutline &&
    _sameRequest(left.request, right.request);

bool _samePreparedAdmission(
  AutomaticOutlinePreparedAdmission left,
  AutomaticOutlinePreparedAdmission right,
) =>
    _samePreparedRequest(left, right) &&
    left.createdAt.isAtSameMomentAs(right.createdAt) &&
    (left.accepted == null && right.accepted == null ||
        left.accepted != null &&
            right.accepted != null &&
            _sameAcceptedRun(left.accepted!, right.accepted!));

bool _validPreparedReplacement(
  AutomaticOutlinePreparedAdmission expected,
  AutomaticOutlinePreparedAdmission replacement,
) =>
    expected.accepted == null &&
    replacement.accepted == null &&
    _validPreparedAdmission(expected) &&
    _validPreparedAdmission(replacement) &&
    replacement.backendAdmissionAttempt ==
        expected.backendAdmissionAttempt + 1 &&
    expected.attemptId == replacement.attemptId &&
    expected.localNoteId == replacement.localNoteId &&
    expected.operationId == replacement.operationId &&
    expected.allowExistingAutomaticOutline ==
        replacement.allowExistingAutomaticOutline &&
    expected.createdAt.isAtSameMomentAs(replacement.createdAt) &&
    _sameRequestExceptIdempotencyKey(expected.request, replacement.request);

bool _sameRequest(NoteFileAgentRequest left, NoteFileAgentRequest right) =>
    left.noteId == right.noteId &&
    left.inputPart == right.inputPart &&
    left.inputPartRevisionId == right.inputPartRevisionId &&
    left.targetPart == right.targetPart &&
    left.targetPartRevisionId == right.targetPartRevisionId &&
    left.instruction == right.instruction &&
    left.selector.agentProfileId == right.selector.agentProfileId &&
    listEquals(left.selector.skillProfileIds, right.selector.skillProfileIds) &&
    left.idempotencyKey == right.idempotencyKey &&
    left.modelProfileId == right.modelProfileId;

bool _sameRequestExceptIdempotencyKey(
  NoteFileAgentRequest left,
  NoteFileAgentRequest right,
) =>
    left.noteId == right.noteId &&
    left.inputPart == right.inputPart &&
    left.inputPartRevisionId == right.inputPartRevisionId &&
    left.targetPart == right.targetPart &&
    left.targetPartRevisionId == right.targetPartRevisionId &&
    left.instruction == right.instruction &&
    left.selector.agentProfileId == right.selector.agentProfileId &&
    listEquals(left.selector.skillProfileIds, right.selector.skillProfileIds) &&
    left.modelProfileId == right.modelProfileId;

bool _sameAcceptedRun(
  NoteFileAgentRunSnapshot left,
  NoteFileAgentRunSnapshot right,
) =>
    left.fileAgentRunId == right.fileAgentRunId &&
    left.noteId == right.noteId &&
    left.status == right.status &&
    left.agentRunId == right.agentRunId &&
    left.inputPart == right.inputPart &&
    left.inputPartRevisionId == right.inputPartRevisionId &&
    left.targetPart == right.targetPart &&
    left.targetPartRevisionId == right.targetPartRevisionId &&
    left.outputPartRevisionId == right.outputPartRevisionId &&
    left.failureCode == right.failureCode;

bool _sameTerminalIdentity(
  AutomaticOutlineTerminalRecord left,
  AutomaticOutlineTerminalRecord right,
) => left.attemptId == right.attemptId && left.operationId == right.operationId;

bool _sameTerminalLifecycle(
  AutomaticOutlineTerminalRecord terminal,
  AutomaticOutlinePreparedAdmission admission,
) =>
    terminal.attemptId == admission.attemptId &&
    terminal.operationId == admission.operationId &&
    terminal.remoteNoteId == admission.remoteNoteId &&
    terminal.inputRawRevisionId == admission.inputRawRevisionId &&
    terminal.targetOutlineRevisionId == admission.targetOutlineRevisionId;

bool _sameTerminalResult(
  AutomaticOutlineTerminalRecord left,
  AutomaticOutlineTerminalRecord right,
) =>
    left.remoteNoteId == right.remoteNoteId &&
    left.inputRawRevisionId == right.inputRawRevisionId &&
    left.targetOutlineRevisionId == right.targetOutlineRevisionId &&
    left.status == right.status &&
    (left.fileAgentRunId == null ||
        right.fileAgentRunId == null ||
        left.fileAgentRunId == right.fileAgentRunId) &&
    left.outputOutlineRevisionId == right.outputOutlineRevisionId;

AutomaticOutlineTerminalRecord _terminalWithFileAgentRunId(
  AutomaticOutlineTerminalRecord value,
  String fileAgentRunId,
) => AutomaticOutlineTerminalRecord(
  attemptId: value.attemptId,
  remoteNoteId: value.remoteNoteId,
  operationId: value.operationId,
  inputRawRevisionId: value.inputRawRevisionId,
  targetOutlineRevisionId: value.targetOutlineRevisionId,
  status: value.status,
  fileAgentRunId: fileAgentRunId,
  outputOutlineRevisionId: value.outputOutlineRevisionId,
  recordedAt: value.recordedAt,
);

bool _sameRecoveryRecord(
  _AutomaticOutlineAssetRecovery left,
  _AutomaticOutlineAssetRecovery right,
) =>
    jsonEncode(_recoveryRecordValue(left)) ==
    jsonEncode(_recoveryRecordValue(right));

Map<String, Object?> _recoveryRecordValue(
  _AutomaticOutlineAssetRecovery value,
) => <String, Object?>{
  'active': value.active == null ? null : _preparedToJson(value.active!),
  'terminals': value.terminals.map(_terminalToJson).toList(),
};

Map<String, Object?> _preparedToJson(AutomaticOutlinePreparedAdmission value) =>
    <String, Object?>{
      'attemptId': value.attemptId,
      'localNoteId': value.localNoteId,
      'operationId': value.operationId,
      'backendAdmissionAttempt': value.backendAdmissionAttempt,
      'allowExistingAutomaticOutline': value.allowExistingAutomaticOutline,
      'createdAt': value.createdAt.toUtc().toIso8601String(),
      'request': _requestToJson(value.request),
      if (value.accepted != null) 'accepted': _acceptedToJson(value.accepted!),
    };

Map<String, Object?> _requestToJson(NoteFileAgentRequest value) =>
    <String, Object?>{
      'noteId': value.noteId,
      'inputPart': value.inputPart.wireName,
      'inputPartRevisionId': value.inputPartRevisionId,
      'targetPart': value.targetPart.wireName,
      'targetPartRevisionId': value.targetPartRevisionId,
      'instruction': value.instruction,
      'agentProfileId': value.selector.agentProfileId,
      'skillProfileIds': value.selector.skillProfileIds,
      'idempotencyKey': value.idempotencyKey,
      if (value.modelProfileId != null) 'modelProfileId': value.modelProfileId,
    };

Map<String, Object?> _acceptedToJson(NoteFileAgentRunSnapshot value) =>
    <String, Object?>{
      'fileAgentRunId': value.fileAgentRunId,
      'noteId': value.noteId,
      'status': value.status,
      'agentRunId': value.agentRunId,
      'inputPart': value.inputPart.wireName,
      'inputPartRevisionId': value.inputPartRevisionId,
      'targetPart': value.targetPart.wireName,
      'targetPartRevisionId': value.targetPartRevisionId,
      if (value.outputPartRevisionId != null)
        'outputPartRevisionId': value.outputPartRevisionId,
      if (value.failureCode != null) 'failureCode': value.failureCode,
    };

Map<String, Object?> _terminalToJson(AutomaticOutlineTerminalRecord value) =>
    <String, Object?>{
      'attemptId': value.attemptId,
      'remoteNoteId': value.remoteNoteId,
      'operationId': value.operationId,
      'inputRawRevisionId': value.inputRawRevisionId,
      'targetOutlineRevisionId': value.targetOutlineRevisionId,
      'status': value.status,
      if (value.fileAgentRunId != null) 'fileAgentRunId': value.fileAgentRunId,
      if (value.outputOutlineRevisionId != null)
        'outputOutlineRevisionId': value.outputOutlineRevisionId,
      'recordedAt': value.recordedAt.toUtc().toIso8601String(),
    };

_AutomaticOutlineAssetRecovery _recoveryRecordFromJson(
  Object? raw, {
  required String expectedScopeDigest,
  required String expectedRemoteNoteId,
}) {
  final value = _objectMap(raw);
  if (value == null ||
      value['schema'] != 1 ||
      value['scopeDigest'] != expectedScopeDigest ||
      value['remoteNoteId'] != expectedRemoteNoteId ||
      value['terminals'] is! List) {
    throw const FormatException();
  }
  final activeValue = value['active'];
  final active = activeValue == null ? null : _preparedFromJson(activeValue);
  if (activeValue != null && active == null ||
      active != null && active.remoteNoteId != expectedRemoteNoteId) {
    throw const FormatException();
  }
  final terminals = <AutomaticOutlineTerminalRecord>[];
  for (final item in value['terminals']! as List) {
    final terminal = _terminalFromJson(item);
    if (terminal == null || terminal.remoteNoteId != expectedRemoteNoteId) {
      throw const FormatException();
    }
    terminals.add(terminal);
  }
  final lifecycleKeys = <(String, String)>{};
  if (terminals.length > 32 ||
      terminals.any(
        (terminal) =>
            !lifecycleKeys.add((terminal.attemptId, terminal.operationId)),
      ) ||
      active != null &&
          terminals.any(
            (terminal) =>
                terminal.attemptId == active.attemptId &&
                terminal.operationId == active.operationId,
          )) {
    throw const FormatException();
  }
  return _AutomaticOutlineAssetRecovery(
    active: active,
    terminals: List<AutomaticOutlineTerminalRecord>.unmodifiable(terminals),
  );
}

AutomaticOutlinePreparedAdmission? _preparedFromJson(Object? raw) {
  final value = _objectMap(raw);
  if (value == null) return null;
  final attemptId = _journalText(value['attemptId'], maximumLength: 128);
  final localNoteId = _journalText(value['localNoteId'], maximumLength: 512);
  final operationId = _journalText(value['operationId'], maximumLength: 256);
  final backendAdmissionAttempt = value['backendAdmissionAttempt'] ?? 0;
  final allowExisting = value['allowExistingAutomaticOutline'];
  final createdAt = _journalDate(value['createdAt']);
  final request = _requestFromJson(value['request']);
  final acceptedValue = value['accepted'];
  final accepted = acceptedValue == null
      ? null
      : _acceptedFromJson(acceptedValue);
  if (attemptId == null ||
      localNoteId == null ||
      operationId == null ||
      !isAutomaticOutlineOperationId(operationId) ||
      backendAdmissionAttempt is! int ||
      backendAdmissionAttempt < 0 ||
      backendAdmissionAttempt > 10000 ||
      allowExisting is! bool ||
      createdAt == null ||
      request == null ||
      acceptedValue != null && accepted == null) {
    return null;
  }
  final result = AutomaticOutlinePreparedAdmission(
    attemptId: attemptId,
    localNoteId: localNoteId,
    operationId: operationId,
    request: request,
    allowExistingAutomaticOutline: allowExisting,
    createdAt: createdAt,
    backendAdmissionAttempt: backendAdmissionAttempt,
    accepted: accepted,
  );
  return _validPreparedAdmission(result) &&
          (accepted == null || result.withAccepted(accepted) != null)
      ? result
      : null;
}

NoteFileAgentRequest? _requestFromJson(Object? raw) {
  final value = _objectMap(raw);
  if (value == null) return null;
  final noteId = _journalText(value['noteId'], maximumLength: 512);
  final inputPart = _partFromJson(value['inputPart']);
  final inputRevision = _journalText(
    value['inputPartRevisionId'],
    maximumLength: 512,
  );
  final targetPart = _partFromJson(value['targetPart']);
  final targetRevision = _journalText(
    value['targetPartRevisionId'],
    maximumLength: 512,
  );
  final instruction = _journalText(value['instruction'], maximumLength: 8192);
  final agentProfileId = _journalText(
    value['agentProfileId'],
    maximumLength: 256,
  );
  final rawSkills = value['skillProfileIds'];
  final idempotencyKey = _journalText(
    value['idempotencyKey'],
    maximumLength: 256,
  );
  final modelProfileId = value['modelProfileId'] == null
      ? null
      : _journalText(value['modelProfileId'], maximumLength: 256);
  if (noteId == null ||
      inputPart != NoteFileAgentPart.raw ||
      inputRevision == null ||
      targetPart != NoteFileAgentPart.outline ||
      targetRevision == null ||
      instruction == null ||
      agentProfileId == null ||
      rawSkills is! List ||
      rawSkills.isEmpty ||
      rawSkills.length > 32 ||
      idempotencyKey == null ||
      value['modelProfileId'] != null && modelProfileId == null) {
    return null;
  }
  final skills = <String>[];
  for (final skill in rawSkills) {
    final normalized = _journalText(skill, maximumLength: 256);
    if (normalized == null) return null;
    skills.add(normalized);
  }
  return NoteFileAgentRequest(
    noteId: noteId,
    inputPart: NoteFileAgentPart.raw,
    inputPartRevisionId: inputRevision,
    targetPart: NoteFileAgentPart.outline,
    targetPartRevisionId: targetRevision,
    instruction: instruction,
    selector: NoteFileAgentSelector(
      agentProfileId: agentProfileId,
      skillProfileIds: List<String>.unmodifiable(skills),
    ),
    idempotencyKey: idempotencyKey,
    modelProfileId: modelProfileId,
  );
}

NoteFileAgentRunSnapshot? _acceptedFromJson(Object? raw) {
  final value = _objectMap(raw);
  if (value == null) return null;
  final fileRunId = _journalText(value['fileAgentRunId'], maximumLength: 512);
  final noteId = _journalText(value['noteId'], maximumLength: 512);
  final status = _journalText(value['status'], maximumLength: 64);
  final agentRunId = _journalText(value['agentRunId'], maximumLength: 512);
  final inputPart = _partFromJson(value['inputPart']);
  final inputRevision = _journalText(
    value['inputPartRevisionId'],
    maximumLength: 512,
  );
  final targetPart = _partFromJson(value['targetPart']);
  final targetRevision = _journalText(
    value['targetPartRevisionId'],
    maximumLength: 512,
  );
  final outputRevision = value['outputPartRevisionId'] == null
      ? null
      : _journalText(value['outputPartRevisionId'], maximumLength: 512);
  final failureCode = value['failureCode'] == null
      ? null
      : _journalText(value['failureCode'], maximumLength: 256);
  if (fileRunId == null ||
      noteId == null ||
      status == null ||
      agentRunId == null ||
      inputPart != NoteFileAgentPart.raw ||
      inputRevision == null ||
      targetPart != NoteFileAgentPart.outline ||
      targetRevision == null ||
      value['outputPartRevisionId'] != null && outputRevision == null ||
      value['failureCode'] != null && failureCode == null) {
    return null;
  }
  final result = NoteFileAgentRunSnapshot(
    fileAgentRunId: fileRunId,
    noteId: noteId,
    status: status,
    agentRunId: agentRunId,
    inputPart: NoteFileAgentPart.raw,
    inputPartRevisionId: inputRevision,
    targetPart: NoteFileAgentPart.outline,
    targetPartRevisionId: targetRevision,
    outputPartRevisionId: outputRevision,
    failureCode: failureCode,
  );
  return _validAcceptedRun(result) ? result : null;
}

AutomaticOutlineTerminalRecord? _terminalFromJson(Object? raw) {
  final value = _objectMap(raw);
  if (value == null) return null;
  final attemptId = _journalText(value['attemptId'], maximumLength: 128);
  final remoteNoteId = _journalText(value['remoteNoteId'], maximumLength: 512);
  final operationId = _journalText(value['operationId'], maximumLength: 256);
  final inputRevision = _journalText(
    value['inputRawRevisionId'],
    maximumLength: 512,
  );
  final targetRevision = _journalText(
    value['targetOutlineRevisionId'],
    maximumLength: 512,
  );
  final status = _journalText(value['status'], maximumLength: 64);
  final fileAgentRunId = value['fileAgentRunId'] == null
      ? null
      : _journalText(value['fileAgentRunId'], maximumLength: 512);
  final outputRevision = value['outputOutlineRevisionId'] == null
      ? null
      : _journalText(value['outputOutlineRevisionId'], maximumLength: 512);
  final recordedAt = _journalDate(value['recordedAt']);
  if (attemptId == null ||
      remoteNoteId == null ||
      operationId == null ||
      inputRevision == null ||
      targetRevision == null ||
      status == null ||
      recordedAt == null ||
      value['fileAgentRunId'] != null && fileAgentRunId == null ||
      value['outputOutlineRevisionId'] != null && outputRevision == null) {
    return null;
  }
  final result = AutomaticOutlineTerminalRecord(
    attemptId: attemptId,
    remoteNoteId: remoteNoteId,
    operationId: operationId,
    inputRawRevisionId: inputRevision,
    targetOutlineRevisionId: targetRevision,
    status: status,
    fileAgentRunId: fileAgentRunId,
    outputOutlineRevisionId: outputRevision,
    recordedAt: recordedAt,
  );
  return _validTerminalRecord(result) ? result : null;
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) return null;
  return Map<String, Object?>.from(value);
}

NoteFileAgentPart? _partFromJson(Object? value) {
  if (value is! String) return null;
  for (final part in NoteFileAgentPart.values) {
    if (part.wireName == value) return part;
  }
  return null;
}

DateTime? _journalDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String _requiredScope(String value, String name) =>
    _requiredJournalText(value, name, maximumLength: 512);

String _requiredJournalText(
  Object? value,
  String name, {
  required int maximumLength,
}) {
  final normalized = _journalText(value, maximumLength: maximumLength);
  if (normalized == null) {
    throw ArgumentError.value(value, name, 'must be safe non-empty text');
  }
  return normalized;
}

String? _journalText(Object? value, {required int maximumLength}) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maximumLength) return null;
  if (normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return null;
  }
  return normalized;
}

bool _canonicalJournalText(String value, {required int maximumLength}) =>
    _journalText(value, maximumLength: maximumLength) == value;

String? _normalizedRemoteNoteId(String value) =>
    _journalText(value, maximumLength: 512);
