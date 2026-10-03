import '../../../core/database/app_database.dart';
import '../domain/digital_twin_material.dart';
import '../domain/digital_twin_models.dart';
import '../domain/digital_twin_operation.dart';
import '../domain/document_change_proposal_models.dart';

final class DigitalTwinMaterialStore {
  DigitalTwinMaterialStore({
    required AppDatabase database,
    required String scope,
  }) : _database = database,
       _scope = scope;

  final AppDatabase _database;
  final String _scope;
  static const _source = 'digital_twin_material';

  List<DigitalTwinMaterial> read() {
    final items = <DigitalTwinMaterial>[];
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.materialIngestionDrafts,
    )) {
      if (record['owner_scope'] != _scope || record['source'] != _source)
        continue;
      final payload = record['material'];
      if (payload is! Map)
        throw const FormatException('DIGITAL_TWIN_QUEUE_INVALID');
      items.add(
        DigitalTwinMaterial.fromJson(Map<String, Object?>.from(payload)),
      );
    }
    items.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List.unmodifiable(items);
  }

  Future<void> save(DigitalTwinMaterial item) async {
    _writeMaterial(item);
    await _database.flushPersistence();
  }

  Future<void> saveAll(List<DigitalTwinMaterial> items) => _transaction(() {
    for (final item in items) {
      _writeMaterial(item);
    }
  });

  void _writeMaterial(DigitalTwinMaterial item) {
    _database.upsertRecord(
      LocalTableName.materialIngestionDrafts,
      'digital-twin-material:$_scope:${item.id}',
      {'owner_scope': _scope, 'source': _source, 'material': item.toJson()},
    );
  }

  Future<void> approve(List<String> ids) => _transaction(() {
    for (final item in read()) {
      if (!ids.contains(item.id) || !item.canSubmit) continue;
      _writeMaterial(
        item.copyWith(
          status: item.source == null
              ? DigitalTwinMaterialStatus.waitingSource
              : DigitalTwinMaterialStatus.submitting,
          clearError: true,
        ),
      );
    }
  });

  Future<DigitalTwinMaterial> updateMaterial(
    String id,
    DigitalTwinMaterial Function(DigitalTwinMaterial) update,
  ) async {
    late DigitalTwinMaterial result;
    await _transaction(() {
      final latest = read().firstWhere((item) => item.id == id);
      result = update(latest);
      _writeMaterial(result);
    });
    return result;
  }

  Map<String, Object?> get _session {
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.materialIngestionDrafts,
    )) {
      if (record['owner_scope'] == _scope &&
          record['source'] == 'digital_twin_review') {
        return Map<String, Object?>.from(record['session']! as Map);
      }
    }
    return {};
  }

  String? get pendingConfirmationId => _session['confirmationId'] as String?;

  DigitalTwinRestoreCommand? get pendingRestoreCommand =>
      _session['restoreCommand'] is Map
      ? DigitalTwinRestoreCommand.fromJson(
          Map<String, Object?>.from(_session['restoreCommand']! as Map),
        )
      : null;

  DigitalTwinRestore? get lastRestore => _session['restoreReport'] == null
      ? null
      : DigitalTwinRestore.fromValue(_session['restoreReport']);

  Future<void> prepareRestore(
    DigitalTwinRestoreCommand command,
  ) => _transaction(() {
    if (pendingConfirmationCommand != null ||
        pendingConfirmationId != null ||
        pendingProposalCommands.isNotEmpty ||
        (pendingRestoreCommand != null &&
            pendingRestoreCommand!.idempotencyKey != command.idempotencyKey)) {
      throw const DigitalTwinApiException('DIGITAL_TWIN_OPERATION_IN_PROGRESS');
    }
    final frozen = pendingRestoreCommand ?? command;
    _archiveOperation(frozen.idempotencyKey, {
      'kind': 'restore',
      'command': frozen.toJson(),
      'state': 'pending',
    });
    _writeSession({..._session, 'restoreCommand': frozen.toJson()});
  });

  Future<void> recordRestoreReceipt(
    DigitalTwinRestoreCommand command,
    DigitalTwinRestore receipt,
  ) => _transaction(() {
    final pending = pendingRestoreCommand;
    if (pending == null || pending.idempotencyKey != command.idempotencyKey)
      return;
    if (receipt.versionId != command.versionId ||
        receipt.taskId.trim().isEmpty) {
      throw const DigitalTwinApiException(
        'DIGITAL_TWIN_RESTORE_RECEIPT_INVALID',
      );
    }
    final accepted = pending.withReceipt(receipt);
    _archiveOperation(command.idempotencyKey, {
      'kind': 'restore',
      'command': accepted.toJson(),
      'state': 'pending',
    });
    _writeSession({
      ..._session,
      'restoreCommand': accepted.toJson(),
      'restoreReport': accepted.toJson()['receipt'],
    });
  });

  Future<void> settleRestore(DigitalTwinRestoreCommand command) =>
      _transaction(() {
        final pending = pendingRestoreCommand;
        if (pending == null ||
            pending.idempotencyKey != command.idempotencyKey ||
            pending.receipt == null)
          return;
        _archiveOperation(command.idempotencyKey, {
          'kind': 'restore',
          'command': pending.toJson(),
          'state': pending.receipt!.state == 'failed' ? 'failed' : 'settled',
        });
        _writeSession({
          ..._session,
          'restoreCommand': null,
          'restoreReport': pending.toJson()['receipt'],
        });
      });

  List<DigitalTwinRevisionRecord> get revisionArchive {
    final entries = <DigitalTwinRevisionRecord>[];
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.materialIngestionDrafts,
    )) {
      if (record['owner_scope'] != _scope ||
          record['source'] != 'digital_twin_operation') {
        continue;
      }
      final value = Map<String, Object?>.from(record['operation']! as Map);
      if (!const {'revise', 'regenerate'}.contains(value['kind'])) continue;
      entries.add(
        DigitalTwinRevisionRecord(
          command: DigitalTwinProposalCommand.fromJson(
            Map<String, Object?>.from(value['command']! as Map),
          ),
          state: value['state']! as String,
          result: value['result'] as String?,
        ),
      );
    }
    entries.sort(
      (first, second) => first.command.proposal.proposal.proposalVersion
          .compareTo(second.command.proposal.proposal.proposalVersion),
    );
    return List.unmodifiable(entries);
  }

  DigitalTwinConfirmationCommand? get pendingConfirmationCommand =>
      _session['confirmationCommand'] is Map
      ? DigitalTwinConfirmationCommand.fromJson(
          Map<String, Object?>.from(_session['confirmationCommand']! as Map),
        )
      : null;

  DigitalTwinConfirmation? get lastReport => _session['lastReport'] is Map
      ? DigitalTwinConfirmation.fromValue(_session['lastReport'])
      : null;

  List<DigitalTwinProposalCommand> get pendingProposalCommands => [
    for (final entry in _session['proposalCommands'] as List? ?? const [])
      DigitalTwinProposalCommand.fromJson(
        Map<String, Object?>.from(entry as Map),
      ),
  ];

  Future<void> prepareConfirmation(
    DigitalTwinConfirmationCommand command,
  ) async {
    final existing = pendingConfirmationCommand;
    if (existing != null && existing.idempotencyKey != command.idempotencyKey ||
        existing == null && pendingConfirmationId != null ||
        pendingProposalCommands.isNotEmpty ||
        pendingRestoreCommand != null) {
      throw const DigitalTwinApiException('DIGITAL_TWIN_OPERATION_IN_PROGRESS');
    }
    _archiveOperation(command.idempotencyKey, {
      'kind': 'confirmation',
      'command': command.toJson(),
      'state': 'pending',
    });
    await _saveSession({
      ..._session,
      'confirmationCommand': command.toJson(),
      'proposalIds': command.proposalIds,
    });
  }

  Future<void> rejectConfirmationCommand(
    DigitalTwinConfirmationCommand command,
    String errorCode,
  ) => _transaction(() {
    if (pendingConfirmationId != null ||
        pendingConfirmationCommand?.idempotencyKey != command.idempotencyKey)
      return;
    _archiveOperation(command.idempotencyKey, {
      'kind': 'confirmation',
      'command': command.toJson(),
      'state': 'rejected',
      'errorCode': errorCode,
    });
    _writeSession({
      ..._session,
      'confirmationCommand': null,
      'proposalIds': <String>[],
      'lastConfirmationError': errorCode,
    });
  });

  Future<void> prepareProposalCommands(
    List<DigitalTwinProposalCommand> commands,
  ) async {
    if (pendingConfirmationCommand != null ||
        pendingConfirmationId != null ||
        pendingRestoreCommand != null) {
      throw const DigitalTwinApiException(
        'DIGITAL_TWIN_CONFIRMATION_IN_PROGRESS',
      );
    }
    final existing = pendingProposalCommands;
    if (existing.any(
      (entry) => !commands.any(
        (command) => command.idempotencyKey == entry.idempotencyKey,
      ),
    )) {
      throw const DigitalTwinApiException('DIGITAL_TWIN_REVISION_IN_PROGRESS');
    }
    final events = revisionEvents.toList();
    for (final command in commands) {
      final stored =
          existing
              .where((entry) => entry.idempotencyKey == command.idempotencyKey)
              .firstOrNull ??
          command;
      _archiveOperation(command.idempotencyKey, {
        'kind': command.operation.name,
        'command': stored.toJson(),
        'state': 'pending',
      });
      final eventId = '${command.idempotencyKey}:user';
      if (!events.any((event) => event.eventId == eventId)) {
        events.add(
          DigitalTwinRevisionEvent(
            eventId: eventId,
            proposalId: command.proposal.proposal.proposalId,
            text: command.instruction,
            isUser: true,
          ),
        );
      }
    }
    await _saveSession({
      ..._session,
      'proposalCommands': [
        for (final command in commands)
          (existing
                      .where(
                        (entry) =>
                            entry.idempotencyKey == command.idempotencyKey,
                      )
                      .firstOrNull ??
                  command)
              .toJson(),
      ],
      'revisionEvents': events
          .skip(events.length > 100 ? events.length - 100 : 0)
          .map((entry) => entry.toJson())
          .toList(),
    });
  }

  Future<void> recordProposalReceipt(
    DigitalTwinProposalCommand command,
    DocumentChangeProposalSnapshot receipt,
  ) => _transaction(() {
    final commands = pendingProposalCommands;
    if (!commands.any(
      (entry) => entry.idempotencyKey == command.idempotencyKey,
    ))
      return;
    if (command.operation == DigitalTwinProposalOperation.regenerate) {
      _replaceProposal(
        command.proposal.proposal.proposalId,
        receipt.proposal.proposalId,
      );
    }
    _writeSession({
      ..._session,
      'proposalCommands': [
        for (final entry in commands)
          (entry.idempotencyKey == command.idempotencyKey &&
                      entry.receipt == null
                  ? entry.withReceipt(receipt)
                  : entry)
              .toJson(),
      ],
    });
  });

  Future<void> recordPreparedProposal(DigitalTwinProposalCommand command) =>
      _saveSession({
        ..._session,
        'proposalCommands': [
          for (final entry in pendingProposalCommands)
            (entry.idempotencyKey == command.idempotencyKey ? command : entry)
                .toJson(),
        ],
      });

  Future<void> finishProposalCommand(
    DigitalTwinProposalCommand command,
    String message,
  ) async {
    final commands = pendingProposalCommands;
    final stored = commands
        .where((entry) => entry.idempotencyKey == command.idempotencyKey)
        .firstOrNull;
    if (stored == null) return;
    _archiveOperation(command.idempotencyKey, {
      'kind': command.operation.name,
      'command': stored.toJson(),
      'state': 'settled',
      'result': message,
    });
    final event = DigitalTwinRevisionEvent(
      eventId: '${command.idempotencyKey}:result',
      proposalId: stored.currentProposalId,
      text: message,
      isUser: false,
    );
    final events = [
      ...revisionEvents.where((entry) => entry.eventId != event.eventId),
      event,
    ];
    final history = [
      ..._session['operationHistory'] as List? ?? const [],
      stored.toJson(),
    ];
    await _saveSession({
      ..._session,
      'proposalCommands': commands
          .where((entry) => entry.idempotencyKey != command.idempotencyKey)
          .map((entry) => entry.toJson())
          .toList(),
      'operationHistory': history
          .skip(history.length > 100 ? history.length - 100 : 0)
          .toList(),
      'revisionEvents': events
          .skip(events.length > 100 ? events.length - 100 : 0)
          .map((entry) => entry.toJson())
          .toList(),
    });
  }

  List<String> get pendingProposalIds =>
      List<String>.from(_session['proposalIds'] as List? ?? const []);

  List<DigitalTwinRevisionEvent> get revisionEvents => [
    for (final entry in _session['revisionEvents'] as List? ?? const [])
      DigitalTwinRevisionEvent.fromJson(
        Map<String, Object?>.from(entry as Map),
      ),
  ];

  Future<bool> recordConfirmation(
    String id,
    List<String> proposalIds, {
    String? idempotencyKey,
  }) async {
    var adopted = false;
    await _transaction(() {
      _archiveOperation('receipt:$id', {
        'kind': 'confirmationReceipt',
        'confirmationId': id,
        'idempotencyKey': idempotencyKey,
        'proposalIds': proposalIds,
      });
      final command = pendingConfirmationCommand;
      final matchesCommand = idempotencyKey == null
          ? command == null
          : command?.idempotencyKey == idempotencyKey;
      if (!matchesCommand ||
          (pendingConfirmationId != null && pendingConfirmationId != id) ||
          pendingRestoreCommand != null ||
          pendingProposalCommands.isNotEmpty)
        return;
      final confirmedIds = proposalIds.isEmpty && pendingConfirmationId == id
          ? pendingProposalIds
          : proposalIds;
      _writeSession({
        ..._session,
        'confirmationId': id,
        'proposalIds': confirmedIds,
      });
      for (final material in read()) {
        if (material.proposalIds.values.any(confirmedIds.contains)) {
          _writeMaterial(
            material.copyWith(
              confirmationId: id,
              confirmationTaskIds: {...material.confirmationTaskIds, id},
            ),
          );
        }
      }
      adopted = true;
    });
    return adopted;
  }

  Future<void> recordConfirmationReport(
    DigitalTwinConfirmation incoming, {
    bool updateCurrent = true,
  }) => _transaction(() {
    final archived = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.materialIngestionDrafts,
      'digital-twin-operation:$_scope:report:${incoming.confirmationTaskId}',
    );
    final archivedValue = (archived?['operation'] as Map?)?['report'];
    final previous = archivedValue == null
        ? null
        : DigitalTwinConfirmation.fromValue(archivedValue);
    final report =
        previous != null &&
            ((previous.isTerminal && !incoming.isTerminal) ||
                (previous.version != null && incoming.version == null) ||
                previous.appliedCount > incoming.appliedCount)
        ? previous
        : incoming;
    _archiveOperation('report:${report.confirmationTaskId}', {
      'kind': 'confirmationReport',
      'report': digitalTwinConfirmationToJson(report),
    });
    final ownsSession =
        updateCurrent &&
        (pendingConfirmationId == null ||
            pendingConfirmationId == report.confirmationTaskId) &&
        (pendingConfirmationCommand == null ||
            pendingConfirmationId == report.confirmationTaskId) &&
        pendingRestoreCommand == null &&
        pendingProposalCommands.isEmpty;
    final previousVersion = lastReport?.version;
    final advancesVersion =
        report.version == null ||
        previousVersion == null ||
        report.version!.versionNumber >= previousVersion.versionNumber;
    if (report.isTerminal && ownsSession && advancesVersion)
      _writeSession({
        ..._session,
        'lastReport': digitalTwinConfirmationToJson(report),
      });
    final versionId = report.version?.versionId;
    if (versionId == null) return;
    for (final material in read()) {
      final outcomes = report.outcomes.where(
        (outcome) =>
            material.proposalIds.values.contains(outcome.proposalId) &&
            outcome.state == DocumentProposalState.applied &&
            outcome.failureCode == null,
      );
      if (outcomes.isEmpty) continue;
      _writeMaterial(
        material.copyWith(
          confirmedVersions: {
            ...material.confirmedVersions,
            for (final outcome in outcomes)
              digitalTwinAppliedEvidenceKey(
                outcome.proposalId,
                outcome.proposalVersion,
              ): versionId,
          },
          versionId: ownsSession && advancesVersion
              ? versionId
              : material.versionId,
          confirmationTaskIds: {
            ...material.confirmationTaskIds,
            report.confirmationTaskId,
          },
        ),
      );
    }
  });

  Future<void> settleConfirmation(String id) => _transaction(() {
    for (final material in read()) {
      if (material.confirmationId == id) {
        _writeMaterial(material.copyWith(clearConfirmation: true));
      }
    }
    if (pendingConfirmationId == id) {
      final command = pendingConfirmationCommand;
      if (command != null)
        _archiveOperation(command.idempotencyKey, {
          'kind': 'confirmation',
          'command': command.toJson(),
          'state': 'settled',
          'confirmationId': id,
        });
      _writeSession({
        ..._session,
        'confirmationId': null,
        'confirmationCommand': null,
        'proposalIds': <String>[],
      });
    }
  });

  Future<void> replaceProposal(String previousId, String replacementId) =>
      _transaction(() => _replaceProposal(previousId, replacementId));

  void _replaceProposal(String previousId, String replacementId) {
    for (final material in read()) {
      if (!material.proposalIds.containsValue(previousId)) continue;
      _writeMaterial(
        material.copyWith(
          proposalIds: material.proposalIds.map(
            (kind, id) => MapEntry(kind, id == previousId ? replacementId : id),
          ),
          status: DigitalTwinMaterialStatus.generating,
          clearConfirmation: true,
          clearError: true,
        ),
      );
    }
  }

  Future<void> appendRevision(DigitalTwinRevisionEvent event) => _saveSession({
    ..._session,
    'revisionEvents': [
      ...revisionEvents
          .where(
            (entry) => event.eventId == null || entry.eventId != event.eventId,
          )
          .skip(revisionEvents.length > 99 ? revisionEvents.length - 99 : 0)
          .map((entry) => entry.toJson()),
      event.toJson(),
    ],
  });

  Future<void> _saveSession(Map<String, Object?> session) async {
    _writeSession(session);
    await _database.flushPersistence();
  }

  void _writeSession(Map<String, Object?> session) {
    _database.upsertRecord(
      LocalTableName.materialIngestionDrafts,
      'digital-twin-review:$_scope',
      {
        'owner_scope': _scope,
        'source': 'digital_twin_review',
        'session': session,
      },
    );
  }

  void _archiveOperation(String id, Map<String, Object?> operation) {
    _database.upsertRecord(
      LocalTableName.materialIngestionDrafts,
      'digital-twin-operation:$_scope:$id',
      {
        'owner_scope': _scope,
        'source': 'digital_twin_operation',
        'operation': operation,
      },
    );
  }

  Future<void> _transaction(void Function() action) async {
    final result = _database.withTransaction<void>((_) => action());
    if (!result.ok)
      throw const DigitalTwinApiException('DIGITAL_TWIN_QUEUE_SAVE_FAILED');
    await _database.flushPersistence();
  }
}
