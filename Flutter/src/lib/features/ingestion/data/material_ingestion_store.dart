import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/material_ingestion.dart';

final class MaterialIngestionStore {
  MaterialIngestionStore({
    required AppDatabase database,
    String ownerScope = 'local',
  }) : _database = database,
       _ownerScope = _opaqueOwnerScope(ownerScope);

  final AppDatabase _database;
  final String _ownerScope;

  AppFailure? save(MaterialIngestionDraft draft) {
    try {
      _database.upsertRecord(
        LocalTableName.materialIngestionDrafts,
        _recordKey(draft.id),
        <String, Object?>{...draft.toRecord(), 'owner_scope': _ownerScope},
      );
      return null;
    } catch (cause) {
      return _failure('MATERIAL_INGESTION_DRAFT_WRITE_FAILED', cause);
    }
  }

  MaterialIngestionDraft? get(String id) {
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.materialIngestionDrafts,
      _recordKey(id),
    );
    return record == null || record['owner_scope'] != _ownerScope
        ? null
        : MaterialIngestionDraft.fromRecord(record);
  }

  List<MaterialIngestionDraft> listRecoverable() {
    final drafts =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.materialIngestionDrafts,
            )
            .where((record) => record['owner_scope'] == _ownerScope)
            .map(MaterialIngestionDraft.fromRecord)
            .whereType<MaterialIngestionDraft>()
            .where((draft) => draft.isRecoverable)
            .toList(growable: false)
          ..sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
    return List<MaterialIngestionDraft>.unmodifiable(drafts);
  }

  List<MaterialIngestionDraft> listAll() {
    final drafts =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.materialIngestionDrafts,
            )
            .where((record) => record['owner_scope'] == _ownerScope)
            .map(MaterialIngestionDraft.fromRecord)
            .whereType<MaterialIngestionDraft>()
            .toList(growable: false)
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<MaterialIngestionDraft>.unmodifiable(drafts);
  }

  String _recordKey(String draftId) => '$_ownerScope:$draftId';
}

// resident-provider: Keeps the material ingestion owner scope value consistent across sibling route consumers.
final materialIngestionOwnerScopeProvider = Provider<String>((ref) => 'local');

String _opaqueOwnerScope(String value) {
  final normalized = value.trim().isEmpty ? 'local' : value.trim();
  if (normalized == 'local') return 'local';
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'user-${digest.substring(0, 32)}';
}

AppFailure _failure(String code, Object cause) => AppFailure(
  code: code,
  category: AppFailureCategory.storage,
  message: 'Material ingestion draft persistence failed',
  userMessageKey: 'ingestion.storage.$code',
  isRetryable: true,
  recoveryActions: const <String>['retry'],
  cause: cause,
);
