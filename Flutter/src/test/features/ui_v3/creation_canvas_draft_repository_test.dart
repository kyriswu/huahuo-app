import 'package:huahuoai_app/app/di/database_providers.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/creation_canvas_draft_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_draft_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';

void main() {
  test(
    'mixed worker draft writes and clears preserve exact FIFO order',
    () async {
      final worker = _RecordingDraftWorker();
      final queue = DatabaseWriteQueue();
      addTearDown(queue.dispose);
      final repository = CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(
          AppDatabase(),
          worker: worker,
          writeQueue: queue,
        ),
        userScope: 'mixed-draft-writes',
      );
      final now = DateTime.utc(2026, 9, 16);
      CreationCanvasDraft draft(int revision) => CreationCanvasDraft(
        title: '有序草稿',
        markdown: '正文 $revision',
        revision: revision,
        createdAt: now,
        updatedAt: now,
      );
      final first = repository.upsertDeferred(draft(1));
      repository.clear();
      repository.upsert(draft(2));
      final last = repository.clearDeferred();
      await first;
      await last;
      await queue.flush();
      expect(worker.operations, ['write:1', 'clear', 'write:2', 'clear']);
      expect(repository.load(), isNull);
      expect(worker.record, isNull);
    },
  );

  test(
    'frozen save snapshots round-trip separately from the working draft',
    () {
      final now = DateTime.now().toUtc();
      final snapshot = CreationCanvasSaveSnapshot(
        rawTitle: '冻结标题',
        title: '冻结标题',
        markdown: '冻结正文',
        documentJson: jsonEncode([
          {'insert': '冻结正文\n'},
        ]),
        documentRevision: 1,
        sessionId: 'frozen-session',
        createdAt: now,
        linkedMaterials: const [],
      );
      var receipt = CreationCanvasHistoryCommitReceipt(
        phase: CreationCanvasHistoryCommitPhase.prepared,
        historyId: 'history-frozen',
        noteId: 'note-frozen',
        noteFingerprint: 'target-frozen',
        editorSnapshotHash: snapshot.hashForBound('note-frozen'),
        snapshot: snapshot,
      );
      final repository = CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(AppDatabase()),
        userScope: 'snapshot-account',
      );
      for (final phase in CreationCanvasHistoryCommitPhase.values) {
        receipt = receipt.advanceTo(phase);
        repository.upsert(
          CreationCanvasDraft(
            title: '迟到标题',
            markdown: '迟到正文',
            sessionId: snapshot.sessionId,
            boundNoteId: phase == CreationCanvasHistoryCommitPhase.prepared
                ? null
                : receipt.noteId,
            boundAssetFingerprint:
                phase == CreationCanvasHistoryCommitPhase.prepared
                ? null
                : receipt.noteFingerprint,
            historyCommitReceipt: receipt,
            revision: 2,
            createdAt: now,
            updatedAt: now,
          ),
        );
        final restored = repository.load()!;
        expect(restored.markdown, '迟到正文');
        expect(
          restored.historyCommitReceipt!.snapshot!.toJson(),
          snapshot.toJson(),
        );
        expect(restored.historyCommitReceipt!.phase, phase);
        expect(restored.unreadableSessionMetadata, isFalse);
      }
      expect(
        () => repository.upsert(
          repository.load()!.copyWith(sessionId: 'other-session'),
        ),
        throwsArgumentError,
      );
      expect(
        () => CreationCanvasHistoryCommitReceipt.fromJson({
          ...receipt.toJson(),
          'editorSnapshotHash': 'tampered',
        }),
        throwsArgumentError,
      );
      expect(
        () => CreationCanvasSaveSnapshot.fromJson({
          ...snapshot.toJson(),
          'version': 99,
        }),
        throwsFormatException,
      );
    },
  );

  test('draft round-trips and repeated upserts keep one account slot', () {
    final database = AppDatabase();
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(database),
      userScope: ' account-a ',
    );
    final createdAt = DateTime.utc(2026, 7, 20, 8);
    final firstUpdatedAt = DateTime.utc(2026, 7, 20, 8, 5);
    final scriptSource = ScriptDraftSourceSnapshot(
      kind: ScriptDraftSourceKind.dailyRecommendation,
      sourceId: 'daily-topic:recommendation-1:topic-1',
      title: '今日选题',
      content: '不可变的选题方向',
      capturedAt: createdAt,
    );
    final scriptReceipt = ScriptDraftGenerationReceipt(
      sessionId: 'script-session-1',
      source: scriptSource,
      createThreadIdempotencyKey: 'create-thread-1',
      messageIdempotencyKey: 'send-message-1',
      cancelIdempotencyKey: 'cancel-run-1',
      phase: ScriptDraftGenerationPhase.ready,
      threadId: 'thread-1',
      agentRunId: 'run-1',
      finalMarkdown: '权威终稿',
      updatedAt: firstUpdatedAt,
    );
    const documentJson = '[{"insert":"第一版\\n","attributes":{"bold":true}}]';
    repository.upsert(
      CreationCanvasDraft(
        title: '  保留标题空格  ',
        markdown: '  # 第一版\n\n正文结尾  ',
        documentJson: documentJson,
        documentFormatVersion: 1,
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'note-1',
            source: V3MaterialSource.note,
            title: '关联笔记',
            summary: '摘要',
          ),
        ],
        sourceTopicId: ' topic-1 ',
        sourceTitle: ' 今日选题 ',
        sessionId: ' canvas-session-1 ',
        entryIdentity: scriptSource.identity,
        scriptDraftReceipt: scriptReceipt,
        boundNoteId: ' manual-note-1 ',
        boundAssetFingerprint: ' asset-fingerprint-1 ',
        savedDraftCleanupPending: true,
        chatThreadId: ' chat-thread-1 ',
        summaryMarkdown: '## 共享摘要',
        sproutMarkdown: '## 共享发芽',
        aiAnnotations: <HuahuoAiAnnotation>[
          HuahuoAiAnnotation(
            id: 'annotation-1',
            stage: HuahuoNoteStage.raw,
            anchor: 'section-1',
            quote: '第一版',
            body: '保留事实',
            createdAt: createdAt,
          ),
        ],
        revision: 1,
        createdAt: createdAt,
        updatedAt: firstUpdatedAt,
      ),
    );

    final restored = repository.load();
    expect(repository.userScope, 'account-a');
    expect(restored?.title, '  保留标题空格  ');
    expect(restored?.markdown, '  # 第一版\n\n正文结尾  ');
    expect(restored?.documentJson, documentJson);
    expect(restored?.documentFormatVersion, 1);
    expect(restored?.unreadableStructuredDocument, isFalse);
    expect(restored?.linkedMaterials, hasLength(1));
    expect(restored?.linkedMaterials.single.id, 'note-1');
    expect(restored?.linkedMaterials.single.source, V3MaterialSource.note);
    expect(restored?.linkedMaterials.single.title, '关联笔记');
    expect(restored?.linkedMaterials.single.summary, '摘要');
    expect(
      () => restored!.linkedMaterials.add(
        const V3LinkedMaterialRef(
          id: 'note-2',
          source: V3MaterialSource.link,
          title: '不可变',
        ),
      ),
      throwsUnsupportedError,
    );
    expect(restored?.sourceTopicId, 'topic-1');
    expect(restored?.sourceTitle, '今日选题');
    expect(restored?.sessionId, 'canvas-session-1');
    expect(restored?.entryIdentity, scriptSource.identity);
    expect(
      restored?.scriptDraftReceipt?.source.identity,
      scriptSource.identity,
    );
    expect(restored?.scriptDraftReceipt?.finalMarkdown, '权威终稿');
    expect(restored?.boundNoteId, 'manual-note-1');
    expect(restored?.boundAssetFingerprint, 'asset-fingerprint-1');
    expect(restored?.savedDraftCleanupPending, isTrue);
    expect(restored?.chatThreadId, 'chat-thread-1');
    expect(restored?.synchronizedNoteId, isNull);
    expect(restored?.summaryMarkdown, '## 共享摘要');
    expect(restored?.sproutMarkdown, '## 共享发芽');
    expect(restored?.aiAnnotations.single.id, 'annotation-1');
    expect(restored?.revision, 1);
    expect(restored?.createdAt, createdAt);
    expect(restored?.updatedAt, firstUpdatedAt);

    repository.upsert(
      CreationCanvasDraft(
        title: '第二版',
        markdown: '正文二',
        revision: 2,
        createdAt: createdAt,
        updatedAt: DateTime.utc(2026, 7, 20, 8, 10),
      ),
    );

    expect(
      database.listRecords(LocalTableName.creationCanvasDrafts),
      hasLength(1),
    );
    expect(repository.load()?.title, '第二版');
    expect(repository.load()?.documentJson, isNull);
    expect(repository.load()?.documentFormatVersion, 0);
    expect(repository.load()?.linkedMaterials, isEmpty);
    expect(repository.load()?.sourceTopicId, isNull);
    expect(repository.load()?.synchronizedNoteId, isNull);
    expect(repository.load()?.summaryMarkdown, isNull);
    expect(repository.load()?.aiAnnotations, isEmpty);
    expect(repository.clear(), isTrue);
    expect(repository.clear(), isFalse);
    expect(repository.load(), isNull);
  });

  test('v5 commit and chat receipts round-trip exact frozen content', () {
    final database = AppDatabase();
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(database),
      userScope: 'receipt-account',
    );
    final now = DateTime.utc(2026, 9, 5, 8);
    const sourceMarkdown = '\n  保留选区首尾空白。  \n';
    final completed = CreationCanvasChatRewriteReceipt(
      threadId: 'chat-thread-1',
      userMessageId: 'user-message-1',
      agentRunId: 'agent-run-1',
      assistantMessageId: 'assistant-message-1',
      rangeStart: 2,
      rangeEnd: 12,
      sourceMarkdown: sourceMarkdown,
      sourceHash: scriptDraftContentHash(sourceMarkdown),
      documentHash: scriptDraftContentHash('document-1'),
      documentRevision: 7,
      selectionScoped: true,
    );
    final pending = CreationCanvasChatRewriteReceipt(
      userMessageId: 'user-message-2',
      rangeStart: 0,
      rangeEnd: 18,
      sourceMarkdown: '完整正文',
      sourceHash: scriptDraftContentHash('完整正文'),
      documentHash: scriptDraftContentHash('document-2'),
      documentRevision: 8,
      selectionScoped: false,
      requestText: '范围约束\n\n请继续改写',
    );
    repository.upsert(
      CreationCanvasDraft(
        title: '待完成提交',
        markdown: '完整正文',
        sessionId: 'canvas-session-1',
        entryIdentity: 'blank',
        boundNoteId: 'note-1',
        boundAssetFingerprint: 'fingerprint-1',
        chatThreadId: 'chat-thread-1',
        historyCommitReceipt: CreationCanvasHistoryCommitReceipt(
          historyId: 'history-1',
          noteId: 'note-1',
          noteFingerprint: 'fingerprint-1',
          editorSnapshotHash: 'editor-snapshot-1',
        ),
        chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[
          completed,
          pending,
        ],
        revision: 8,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final restored = repository.load()!;
    expect(restored.unreadableSessionMetadata, isFalse);
    expect(restored.historyCommitReceipt?.historyId, 'history-1');
    expect(
      restored.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.noteCommitted,
    );
    expect(restored.chatRewriteReceipts, hasLength(2));
    expect(restored.chatRewriteReceipts.first.sourceMarkdown, sourceMarkdown);
    expect(
      restored.chatRewriteReceipts.first.assistantMessageId,
      'assistant-message-1',
    );
    expect(restored.chatRewriteReceipts.last.assistantMessageId, isNull);
    expect(restored.chatRewriteReceipts.last.threadId, isNull);
    expect(restored.chatRewriteReceipts.last.requestText, '范围约束\n\n请继续改写');
    expect(
      restored.chatRewriteReceipts.last.createThreadIdempotencyKey,
      pending.createThreadIdempotencyKey,
    );
    expect(
      restored.chatRewriteReceipts.last.messageIdempotencyKey,
      pending.messageIdempotencyKey,
    );
    expect(
      restored.chatRewriteReceipts.last.submissionPhase,
      CreationCanvasChatSubmissionPhase.prepared,
    );
    final admitted = restored.chatRewriteReceipts.last.bindTurn(
      threadId: 'chat-thread-1',
      agentRunId: 'agent-run-2',
    );
    final reconciled = admitted.bindAssistant('assistant-message-2');
    expect(reconciled.threadId, 'chat-thread-1');
    expect(reconciled.agentRunId, 'agent-run-2');
    expect(reconciled.assistantMessageId, 'assistant-message-2');
    expect(
      reconciled.createThreadIdempotencyKey,
      pending.createThreadIdempotencyKey,
    );
    expect(reconciled.messageIdempotencyKey, pending.messageIdempotencyKey);
    expect(
      () => restored.chatRewriteReceipts.add(completed),
      throwsUnsupportedError,
    );
  });

  test('v5 write-ahead receipt phases preserve their exact binding', () {
    final database = AppDatabase();
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(database),
      userScope: 'phase-receipt-account',
    );
    final now = DateTime.utc(2026, 9, 5, 9);

    for (final phase in CreationCanvasHistoryCommitPhase.values) {
      final prepared = phase == CreationCanvasHistoryCommitPhase.prepared;
      final baseId = prepared ? 'note-1' : null;
      final baseFingerprint = prepared ? 'base-fingerprint' : null;
      repository.upsert(
        CreationCanvasDraft(
          title: '冻结标题',
          markdown: '冻结正文',
          sessionId: 'canvas-session-1',
          boundNoteId: prepared ? baseId : 'note-1',
          boundAssetFingerprint: prepared
              ? baseFingerprint
              : 'target-fingerprint',
          historyCommitReceipt: CreationCanvasHistoryCommitReceipt(
            phase: phase,
            historyId: 'history-1',
            noteId: 'note-1',
            noteFingerprint: 'target-fingerprint',
            editorSnapshotHash: 'snapshot-1',
            baseNoteId: baseId,
            baseNoteFingerprint: baseFingerprint,
          ),
          revision: 3,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final receipt = repository.load()!.historyCommitReceipt!;
      expect(receipt.phase, phase);
      expect(receipt.noteId, 'note-1');
      expect(receipt.noteFingerprint, 'target-fingerprint');
      expect(receipt.baseNoteId, baseId);
      expect(receipt.baseNoteFingerprint, baseFingerprint);
    }
  });

  test('legacy v5 History receipt without phase resumes note committed', () {
    final database = AppDatabase();
    final dao = CreationCanvasDraftDao(database);
    final repository = CreationCanvasDraftRepository(
      dao: dao,
      userScope: 'legacy-receipt-account',
    );
    const timestamp = '2026-09-05T09:00:00.000Z';
    dao.upsert(
      userScope: 'legacy-receipt-account',
      title: '旧版待提交',
      markdown: '旧版冻结正文',
      linkedMaterialsJson: '[]',
      sharedMetadataJson: jsonEncode(<String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'boundNoteId': 'note-1',
        'boundAssetFingerprint': 'target-fingerprint',
        'historyCommitReceipt': <String, Object?>{
          'historyId': 'history-1',
          'noteId': 'note-1',
          'noteFingerprint': 'target-fingerprint',
          'editorSnapshotHash': 'snapshot-1',
        },
      }),
      sourceTopicId: null,
      sourceTitle: null,
      revision: 1,
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    final restored = repository.load()!;
    expect(restored.unreadableSessionMetadata, isFalse);
    expect(
      restored.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.noteCommitted,
    );
  });

  test('contradictory v5 session states fail closed without rewriting', () {
    final database = AppDatabase();
    final dao = CreationCanvasDraftDao(database);
    final repository = CreationCanvasDraftRepository(
      dao: dao,
      userScope: 'invalid-session-account',
    );
    const timestamp = '2026-09-05T08:00:00.000Z';
    final validChatReceipt = <String, Object?>{
      'threadId': 'chat-thread-1',
      'userMessageId': 'user-message-1',
      'assistantMessageId': 'assistant-message-1',
      'rangeStart': 0,
      'rangeEnd': 4,
      'sourceMarkdown': '正文',
      'sourceHash': scriptDraftContentHash('正文'),
      'documentHash': scriptDraftContentHash('document'),
      'documentRevision': 1,
      'selectionScoped': false,
    };
    final pendingChatReceipt = <String, Object?>{
      ...validChatReceipt,
      'userMessageId': 'pending-message-1',
    }..remove('assistantMessageId');
    final invalidPayloads = <Map<String, Object?>>[
      <String, Object?>{'formatVersion': 6},
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'boundNoteId': 'note-1',
        'savedDraftCleanupPending': 'true',
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'boundNoteId': 'note-1',
        'boundAssetFingerprint': 'fingerprint-1',
        'historyCommitReceipt': <String, Object?>{
          'historyId': 'history-1',
          'noteId': 'note-2',
          'noteFingerprint': 'fingerprint-1',
          'editorSnapshotHash': 'snapshot-1',
        },
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'historyCommitReceipt': <String, Object?>{
          'phase': 'futurePhase',
          'historyId': 'history-1',
          'noteId': 'note-1',
          'noteFingerprint': 'target-fingerprint',
          'editorSnapshotHash': 'snapshot-1',
        },
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'boundNoteId': 'note-1',
        'boundAssetFingerprint': 'base-fingerprint',
        'historyCommitReceipt': <String, Object?>{
          'phase': 'prepared',
          'historyId': 'history-1',
          'noteId': 'note-1',
          'noteFingerprint': 'target-fingerprint',
          'editorSnapshotHash': 'snapshot-1',
          'baseNoteId': 'note-1',
        },
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'boundNoteId': 'note-1',
        'boundAssetFingerprint': 'target-fingerprint',
        'historyCommitReceipt': <String, Object?>{
          'phase': 'prepared',
          'historyId': 'history-1',
          'noteId': 'note-1',
          'noteFingerprint': 'target-fingerprint',
          'editorSnapshotHash': 'snapshot-1',
          'baseNoteId': 'note-1',
          'baseNoteFingerprint': 'base-fingerprint',
        },
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'synchronizedNoteId': 'legacy-note-1',
        'historyCommitReceipt': <String, Object?>{
          'phase': 'prepared',
          'historyId': 'history-1',
          'noteId': 'target-note-1',
          'noteFingerprint': 'target-fingerprint',
          'editorSnapshotHash': 'snapshot-1',
        },
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'chatThreadId': 'chat-thread-1',
        'chatRewriteReceipts': <Map<String, Object?>>[
          validChatReceipt,
          <String, Object?>{
            ...validChatReceipt,
            'userMessageId': 'user-message-2',
          },
        ],
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'chatThreadId': 'chat-thread-1',
        'chatRewriteReceipts': <Map<String, Object?>>[
          pendingChatReceipt,
          <String, Object?>{
            ...pendingChatReceipt,
            'userMessageId': 'pending-message-2',
          },
        ],
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'chatThreadId': 'chat-thread-2',
        'chatRewriteReceipts': <Map<String, Object?>>[pendingChatReceipt],
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'chatRewriteReceipts': <Map<String, Object?>>[
          <String, Object?>{...pendingChatReceipt}..remove('threadId'),
        ],
      },
      <String, Object?>{
        'formatVersion': 5,
        'sessionId': 'canvas-session-1',
        'chatRewriteReceipts': <Map<String, Object?>>[
          <String, Object?>{...validChatReceipt}..remove('threadId'),
        ],
      },
    ];

    for (final payload in invalidPayloads) {
      dao.upsert(
        userScope: 'invalid-session-account',
        title: '必须保留的标题',
        markdown: '必须保留的正文',
        linkedMaterialsJson: '[]',
        sharedMetadataJson: jsonEncode(payload),
        sourceTopicId: null,
        sourceTitle: null,
        revision: 1,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      final before = Map<String, Object?>.from(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single,
      );

      final restored = repository.load();

      expect(restored?.title, '必须保留的标题');
      expect(restored?.markdown, '必须保留的正文');
      expect(restored?.unreadableSessionMetadata, isTrue);
      expect(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single,
        equals(before),
      );
    }
  });

  test('write rejects an unreadable or contradictory recovery state', () {
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(AppDatabase()),
      userScope: 'invalid-write-account',
    );
    final now = DateTime.utc(2026, 9, 5, 8);

    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '不可覆盖',
          markdown: '正文',
          unreadableSessionMetadata: true,
          revision: 1,
          createdAt: now,
          updatedAt: now,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '矛盾回执',
          markdown: '正文',
          sessionId: 'canvas-session-1',
          boundNoteId: 'note-1',
          boundAssetFingerprint: 'fingerprint-1',
          historyCommitReceipt: CreationCanvasHistoryCommitReceipt(
            historyId: 'history-1',
            noteId: 'note-2',
            noteFingerprint: 'fingerprint-1',
            editorSnapshotHash: 'snapshot-1',
          ),
          revision: 1,
          createdAt: now,
          updatedAt: now,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('v4 rows and malformed v5 optional fields preserve Markdown', () {
    final database = AppDatabase();
    const scope = 'legacy-account';
    const createdAt = '2026-07-20T09:00:00.000Z';
    database.upsertRecord(
      LocalTableName.creationCanvasDrafts,
      _draftRecordKey(scope),
      const <String, Object?>{
        'user_scope': scope,
        'title': '旧草稿',
        'markdown': '旧 Markdown',
        'source_topic_id': null,
        'source_title': null,
        'revision': 2,
        'created_at': createdAt,
        'updated_at': createdAt,
      },
    );
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(database),
      userScope: scope,
    );

    final legacy = repository.load();
    expect(legacy?.markdown, '旧 Markdown');
    expect(legacy?.documentJson, isNull);
    expect(legacy?.documentFormatVersion, 0);
    expect(legacy?.unreadableStructuredDocument, isFalse);
    expect(legacy?.linkedMaterials, isEmpty);

    database.upsertRecord(
      LocalTableName.creationCanvasDrafts,
      _draftRecordKey(scope),
      const <String, Object?>{
        'user_scope': scope,
        'title': '可恢复草稿',
        'markdown': '仍可恢复的 Markdown',
        'document_json': 'hex:not-hex',
        'document_format_version': 1,
        'linked_materials_json': 'hex:also-invalid',
        'source_topic_id': null,
        'source_title': null,
        'revision': 3,
        'created_at': createdAt,
        'updated_at': createdAt,
      },
    );

    final recovered = repository.load();
    expect(recovered?.markdown, '仍可恢复的 Markdown');
    expect(recovered?.documentJson, isNull);
    expect(recovered?.documentFormatVersion, 0);
    expect(recovered?.linkedMaterials, isEmpty);
  });

  test(
    'unreadable structured payload is flagged without rewriting its row',
    () {
      final database = AppDatabase();
      final dao = CreationCanvasDraftDao(database);
      final repository = CreationCanvasDraftRepository(
        dao: dao,
        userScope: 'unreadable-account',
      );
      const createdAt = '2026-07-20T09:00:00.000Z';
      dao.upsert(
        userScope: 'unreadable-account',
        title: '',
        markdown: '',
        documentJson: 'not-json',
        documentFormatVersion: 1,
        linkedMaterialsJson: '[]',
        sourceTopicId: null,
        sourceTitle: null,
        revision: 5,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      final before = Map<String, Object?>.from(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single,
      );

      final restored = repository.load();

      expect(restored, isNotNull);
      expect(restored?.markdown, isEmpty);
      expect(restored?.documentJson, isNull);
      expect(restored?.documentFormatVersion, 0);
      expect(restored?.unreadableStructuredDocument, isTrue);
      expect(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single,
        equals(before),
      );

      dao.upsert(
        userScope: 'unreadable-account',
        title: '未来格式',
        markdown: '可用的 Markdown fallback',
        documentJson: '[{"insert":"未来正文\\n"}]',
        documentFormatVersion: 2,
        linkedMaterialsJson: '[]',
        sourceTopicId: null,
        sourceTitle: null,
        revision: 6,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      final future = repository.load();
      expect(future?.markdown, '可用的 Markdown fallback');
      expect(future?.documentJson, isNull);
      expect(future?.documentFormatVersion, 0);
      expect(future?.unreadableStructuredDocument, isTrue);

      final malformedVersionRow = Map<String, Object?>.from(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single,
      )..['document_format_version'] = 1.0;
      database.upsertRecord(
        LocalTableName.creationCanvasDrafts,
        _draftRecordKey('unreadable-account'),
        malformedVersionRow,
      );
      expect(repository.load()?.unreadableStructuredDocument, isTrue);
    },
  );

  test('draft load upsert and clear are isolated by account', () {
    final database = AppDatabase();
    CreationCanvasDraftRepository repositoryFor(String scope) {
      return CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(database),
        userScope: scope,
      );
    }

    final accountA = repositoryFor('account-a');
    final accountB = repositoryFor('account-b');
    final createdAt = DateTime.utc(2026, 7, 20, 9);
    accountA.upsert(
      CreationCanvasDraft(
        title: 'A 草稿',
        markdown: 'A 正文',
        documentJson: '[{"insert":"A 正文\\n"}]',
        documentFormatVersion: 1,
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'account-a-note',
            source: V3MaterialSource.note,
            title: 'A 关联笔记',
          ),
        ],
        revision: 1,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    expect(accountB.load(), isNull);

    accountB.upsert(
      CreationCanvasDraft(
        title: 'B 草稿',
        markdown: 'B 正文',
        documentJson: '[{"insert":"B 正文\\n"}]',
        documentFormatVersion: 1,
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'account-b-note',
            source: V3MaterialSource.link,
            title: 'B 关联笔记',
          ),
        ],
        revision: 4,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    expect(accountA.load()?.title, 'A 草稿');
    expect(accountB.load()?.title, 'B 草稿');
    expect(accountA.load()?.documentJson, contains('A 正文'));
    expect(accountB.load()?.documentJson, contains('B 正文'));
    expect(accountA.load()?.linkedMaterials.single.id, 'account-a-note');
    expect(accountB.load()?.linkedMaterials.single.id, 'account-b-note');
    expect(accountA.clear(), isTrue);
    expect(accountA.load(), isNull);
    expect(accountB.load()?.title, 'B 草稿');
  });

  test('technical prose round-trips through opaque database payloads', () {
    final database = AppDatabase();
    final repository = CreationCanvasDraftRepository(
      dao: CreationCanvasDraftDao(database),
      userScope: 'account-technical',
    );
    final now = DateTime.utc(2026, 7, 20, 9, 30);
    const markdown = '文档示例包含 API key、file:// 协议和 /Users/demo/note.md 路径。';
    const documentJson = '[{"insert":"API key /Users/demo/note.md\\n"}]';
    repository.upsert(
      CreationCanvasDraft(
        title: '技术说明',
        markdown: markdown,
        documentJson: documentJson,
        documentFormatVersion: 1,
        linkedMaterials: const <V3LinkedMaterialRef>[
          V3LinkedMaterialRef(
            id: 'technical-note',
            source: V3MaterialSource.note,
            title: 'API key 示例',
          ),
        ],
        revision: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(repository.load()?.markdown, markdown);
    final stored = database
        .listRecords<LocalDatabaseRecord>(LocalTableName.creationCanvasDrafts)
        .single;
    expect(stored['markdown'], isNot(contains('API key')));
    expect(stored['markdown'], startsWith('hex:'));
    expect(stored['document_json'], isNot(contains('API key')));
    expect(stored['document_json'], startsWith('hex:'));
    expect(stored['linked_materials_json'], isNot(contains('API key')));
    expect(stored['linked_materials_json'], startsWith('hex:'));
  });

  test(
    'deferred autosave survives recreation in the shared SQLite file',
    () async {
      final root = await Directory.systemTemp.createTemp('canvas-worker-');
      final file = File('${root.path}/local.sqlite');
      final snapshotStore = LocalDatabaseSnapshotStore(
        file: file,
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final worker = await DatabaseWorker.start(file: file);
      final queue = DatabaseWriteQueue();
      addTearDown(() async {
        if (!queue.isDisposed) await queue.dispose();
        if (!worker.isDisposed) await worker.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      });
      final repository = CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(
          AppDatabase(snapshotStore: snapshotStore),
          worker: worker,
          writeQueue: queue,
        ),
        userScope: 'canvas-worker-account',
      );
      final now = DateTime.utc(2026, 8, 31, 9);

      final write = repository.upsertDeferred(
        CreationCanvasDraft(
          title: '异步草稿',
          markdown: 'worker 持久化正文',
          revision: 7,
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect(repository.load()?.markdown, 'worker 持久化正文');
      await write;
      await queue.dispose();
      await worker.dispose();

      final recovered = CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(AppDatabase(snapshotStore: snapshotStore)),
        userScope: 'canvas-worker-account',
      );
      expect(recovered.load()?.title, '异步草稿');
      expect(recovered.load()?.markdown, 'worker 持久化正文');
      expect(recovered.load()?.revision, 7);
    },
  );

  test(
    'deferred autosave and clear expose worker failure without sync fallback',
    () async {
      final database = AppDatabase();
      final worker = _FailingRecordWorker();
      final queue = DatabaseWriteQueue();
      addTearDown(queue.dispose);
      final repository = CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(
          database,
          worker: worker,
          writeQueue: queue,
        ),
        userScope: 'canvas-worker-fallback',
      );
      final now = DateTime.utc(2026, 8, 31, 10);

      await expectLater(
        repository.upsertDeferred(
          CreationCanvasDraft(
            title: '待重试草稿',
            markdown: 'worker 失败后保留内存正文',
            revision: 1,
            createdAt: now,
            updatedAt: now,
          ),
        ),
        throwsStateError,
      );
      expect(worker.upsertAttempts, 1);
      expect(repository.load()?.title, '待重试草稿');
      expect(
        CreationCanvasDraftRepository(
          dao: CreationCanvasDraftDao(database),
          userScope: 'canvas-worker-fallback',
        ).load(),
        isNull,
      );
      await expectLater(queue.flush(), throwsStateError);

      await expectLater(repository.clearDeferred(), throwsStateError);
      expect(worker.deleteAttempts, 1);
      expect(repository.load(), isNull);
      await expectLater(queue.flush(), throwsStateError);
    },
  );

  test('provider uses the authenticated scope and shared database', () {
    final database = AppDatabase();
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        authenticatedUserDataScopeProvider.overrideWithValue('provider-user'),
      ],
    );
    addTearDown(container.dispose);

    final repository = container.read(creationCanvasDraftRepositoryProvider);
    expect(repository.userScope, 'provider-user');
    repository.upsert(
      CreationCanvasDraft(
        title: 'Provider 草稿',
        markdown: '由共享数据库恢复',
        revision: 0,
        createdAt: DateTime.utc(2026, 7, 20),
        updatedAt: DateTime.utc(2026, 7, 20),
      ),
    );
    expect(
      CreationCanvasDraftRepository(
        dao: CreationCanvasDraftDao(database),
        userScope: 'provider-user',
      ).load()?.title,
      'Provider 草稿',
    );
  });

  test('invalid drafts are rejected and malformed rows are ignored', () {
    final database = AppDatabase();
    final dao = CreationCanvasDraftDao(database);
    final repository = CreationCanvasDraftRepository(
      dao: dao,
      userScope: 'account-a',
    );
    final createdAt = DateTime.utc(2026, 7, 20, 10);

    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          revision: -1,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          documentJson: '[]',
          documentFormatVersion: 2,
          revision: 0,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          documentJson: 'not-json',
          documentFormatVersion: 1,
          revision: 0,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          documentJson: '[]',
          revision: 0,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          documentFormatVersion: 1,
          revision: 0,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsert(
        CreationCanvasDraft(
          title: '',
          markdown: '',
          revision: 0,
          createdAt: createdAt,
          updatedAt: createdAt.subtract(const Duration(seconds: 1)),
        ),
      ),
      throwsArgumentError,
    );

    dao.upsert(
      userScope: 'account-a',
      title: '损坏草稿',
      markdown: '正文',
      sourceTopicId: null,
      sourceTitle: null,
      revision: 1,
      createdAt: 'not-a-date',
      updatedAt: createdAt.toIso8601String(),
    );
    expect(repository.load(), isNull);
  });
}

final class _FailingRecordWorker implements DatabaseRecordWorkerPort {
  var upsertAttempts = 0;
  var deleteAttempts = 0;

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async {
    upsertAttempts += 1;
    throw StateError('injected worker failure');
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    upsertAttempts += 1;
    throw StateError('injected worker failure');
  }

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async {
    deleteAttempts += 1;
    throw StateError('injected worker failure');
  }

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}

final class _RecordingDraftWorker implements DatabaseRecordWorkerPort {
  final operations = <String>[];
  LocalDatabaseRecord? record;

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async {
    operations.add('write:${record['revision']}');
    this.record = record;
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    for (final entry in records.entries) {
      await upsertRecord(table: table, key: entry.key, record: entry.value);
    }
  }

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async {
    operations.add('clear');
    final existed = record != null;
    record = null;
    return existed;
  }

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async => [
    if (record case final snapshot?) snapshot,
  ];
}

String _draftRecordKey(String userScope) {
  final encoded = base64Url.encode(utf8.encode(userScope)).replaceAll('=', '');
  return 'creation-canvas:$encoded';
}
