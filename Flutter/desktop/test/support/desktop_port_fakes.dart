import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/assets/domain/desktop_assets_port.dart';
import 'package:huahuo_desktop/features/auth/domain/desktop_auth_port.dart';
import 'package:huahuo_desktop/features/book_work/domain/desktop_book_work_port.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_document_sync_port.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_document_import_port.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_raw_note_creator.dart';
import 'package:huahuo_desktop/features/integration/domain/desktop_api_domains_port.dart';
import 'package:huahuo_desktop/shared/services/desktop_service_result.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

final class FakeDesktopAuthPort implements DesktopAuthPort {
  FakeDesktopAuthPort({
    DesktopAuthAccount? account,
    DesktopUserProfile? profile,
    bool signedIn = true,
  }) : account = signedIn
           ? account ??
                 const DesktopAuthAccount(
                   userId: 'test-user',
                   displayName: '花火创作者',
                   workspaceStatus: 'ready',
                   workspaceId: 'workspace-test',
                 )
           : null,
       profile =
           profile ??
           DesktopUserProfile(displayName: account?.displayName ?? '花火创作者');

  DesktopAuthAccount? account;
  DesktopUserProfile profile;

  @override
  Future<DesktopServiceResult<DesktopAuthAccount?>> restoreSession() async =>
      DesktopServiceResult<DesktopAuthAccount?>.success(account);

  @override
  Future<DesktopServiceResult<DesktopSmsChallenge>> requestSmsCode(
    String phone,
  ) async => const DesktopServiceResult<DesktopSmsChallenge>.success(
    DesktopSmsChallenge(smsRequestId: 'sms-test', cooldownSeconds: 60),
  );

  @override
  Future<DesktopServiceResult<DesktopAuthAccount>> signIn({
    required String phone,
    required String smsRequestId,
    required String code,
    required bool agreementAccepted,
  }) async {
    account = const DesktopAuthAccount(
      userId: 'test-user',
      displayName: '花火创作者',
      workspaceStatus: 'ready',
      workspaceId: 'workspace-test',
    );
    return DesktopServiceResult<DesktopAuthAccount>.success(account!);
  }

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> loadProfile() async =>
      DesktopServiceResult<DesktopUserProfile>.success(profile);

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> updateProfile({
    required String displayName,
  }) async {
    profile = DesktopUserProfile(displayName: displayName.trim());
    return DesktopServiceResult<DesktopUserProfile>.success(profile);
  }

  @override
  Future<DesktopServiceResult<void>> retryWorkspaceCreation() async =>
      const DesktopServiceResult<void>.success(null);

  @override
  Future<DesktopServiceResult<void>> signOut() async {
    account = null;
    return const DesktopServiceResult<void>.success(null);
  }
}

final class FakeDesktopRawNoteCreator implements DesktopRawNoteCreator {
  bool unavailable = false;
  final List<DesktopRawNoteCreateRequest> requests =
      <DesktopRawNoteCreateRequest>[];

  @override
  Future<DesktopServiceResult<DesktopCreatedRawNote>> createRawNote(
    DesktopRawNoteCreateRequest request,
  ) async {
    requests.add(request);
    if (unavailable) {
      return const DesktopServiceResult<DesktopCreatedRawNote>.unavailable(
        code: 'TEST_RAW_NOTE_UNAVAILABLE',
        message: '测试文字资产服务不可用',
      );
    }
    return DesktopServiceResult<DesktopCreatedRawNote>.success(
      DesktopCreatedRawNote(
        noteId: 'raw-note-${requests.length}',
        title: request.title,
        rawMarkdown: request.rawMarkdown,
      ),
    );
  }
}

final class FakeDesktopDocumentImportPort implements DesktopDocumentImportPort {
  final List<DesktopDocumentImportRequest> requests =
      <DesktopDocumentImportRequest>[];

  @override
  Future<DesktopServiceResult<DesktopDocumentImportResult>> importDocument(
    DesktopDocumentImportRequest request,
  ) async {
    requests.add(request);
    final format = DesktopDocumentImportFormat.fromFileName(request.fileName);
    if (format == null) {
      return const DesktopServiceResult<DesktopDocumentImportResult>.failure(
        code: 'TEST_DOCUMENT_FORMAT_UNSUPPORTED',
        message: '测试不支持的文档格式',
      );
    }
    final dot = request.fileName.lastIndexOf('.');
    final title = dot > 0
        ? request.fileName.substring(0, dot)
        : request.fileName;
    return DesktopServiceResult<DesktopDocumentImportResult>.success(
      DesktopDocumentImportResult(
        noteId: 'document-import-${requests.length}',
        title: title,
        fileName: request.fileName,
        format: format,
        rawMarkdown: '# $title\n',
      ),
    );
  }
}

final class FakeDesktopAssetsPort implements DesktopAssetsPort {
  const FakeDesktopAssetsPort();

  @override
  Future<DesktopServiceResult<DesktopAssetOverview>> loadOverview() async =>
      const DesktopServiceResult<DesktopAssetOverview>.success(
        DesktopAssetOverview(
          recordingCount: 2,
          transcriptWordCount: 1200,
          contentLineCount: 1,
          lifeEventCount: 3,
          expressionCount: 4,
          syncStatus: 'normal',
          items: <DesktopAssetSummary>[
            DesktopAssetSummary(
              assetType: 'content_line',
              assetId: 'content-line-test',
              title: '测试内容定位',
            ),
          ],
        ),
      );

  @override
  Future<DesktopServiceResult<DesktopAssetItem>> loadMarkdownDocument() async =>
      DesktopServiceResult<DesktopAssetItem>.success(
        DesktopAssetItem(
          id: 'test-assets',
          title: '测试云端资产',
          markdown: '# 测试云端资产\n',
          version: 1,
          updatedAt: DateTime.utc(2026, 7, 31),
        ),
      );

  @override
  Future<DesktopServiceResult<DesktopAssetDetail>> loadDetail({
    required String assetType,
    required String assetId,
  }) async => DesktopServiceResult<DesktopAssetDetail>.success(
    DesktopAssetDetail(
      assetType: assetType,
      assetId: assetId,
      asset: const <String, Object?>{'title': '测试资产'},
      editable: true,
      baseVersion: 1,
      updatedAt: DateTime.utc(2026, 7, 31),
    ),
  );

  @override
  Future<DesktopServiceResult<DesktopAssetSyncReceipt>> requestSync() async =>
      const DesktopServiceResult<DesktopAssetSyncReceipt>.success(
        DesktopAssetSyncReceipt(taskId: 'task-test', status: 'queued'),
      );
}

final class FakeDesktopCatalogPort implements DesktopCatalogPort {
  FakeDesktopCatalogPort({
    this.catalogVersion = 'catalog-desktop-1',
    this.agentAvailable = true,
    this.skillCandidateState = 'enabled',
    this.installationState = 'enabled',
    this.modelAvailable = true,
  });

  String catalogVersion;
  bool agentAvailable;
  String skillCandidateState;
  String installationState;
  bool modelAvailable;
  int createFailureCount = 0;
  int pollFailureCount = 0;
  String createStatus = 'queued';
  String terminalStatus = 'succeeded';
  String terminalCompletionMode = 'normal';
  bool includeDurableResult = true;
  String finalAnswer = '# 发芽洞见\n\n这是服务端生成的正式洞见。';
  final List<String> operations = <String>[];
  final List<AgentRunRequest> createdRequests = <AgentRunRequest>[];
  final List<
    ({
      String workspaceId,
      String noteId,
      String inputPart,
      String inputPartRevisionId,
      String targetPart,
      String targetPartRevisionId,
      String instruction,
      String agentProfileId,
      List<String> skillProfileIds,
    })
  >
  createdFileAgentRuns =
      <
        ({
          String workspaceId,
          String noteId,
          String inputPart,
          String inputPartRevisionId,
          String targetPart,
          String targetPartRevisionId,
          String instruction,
          String agentProfileId,
          List<String> skillProfileIds,
        })
      >[];
  final List<String> idempotencyKeys = <String>[];

  @override
  Future<DesktopServiceResult<AgentProfileCatalog>> loadProfiles() async {
    operations.add('profiles:$catalogVersion');
    return DesktopServiceResult<AgentProfileCatalog>.success(
      AgentProfileCatalog(
        catalogVersion: catalogVersion,
        items: agentAvailable
            ? const <AgentProfileCatalogItem>[
                AgentProfileCatalogItem(
                  agentProfileId: 'faya_germination',
                  displayName: '发芽',
                ),
                AgentProfileCatalogItem(
                  agentProfileId: 'self_media_creation',
                  displayName: '自由创作',
                ),
              ]
            : const <AgentProfileCatalogItem>[],
      ),
    );
  }

  @override
  Future<DesktopServiceResult<List<SkillProfileCatalogItem>>> loadSkills(
    String agentProfileId,
  ) async {
    operations.add('skills:$agentProfileId');
    return DesktopServiceResult<List<SkillProfileCatalogItem>>.success(
      <SkillProfileCatalogItem>[
        SkillProfileCatalogItem(
          skillProfileId: 'viewpoint_germination',
          displayName: '观点发芽',
          installation: skillCandidateState,
        ),
      ],
    );
  }

  @override
  Future<DesktopServiceResult<List<ModelProfileCatalogItem>>> loadModels(
    String agentProfileId,
  ) async {
    operations.add('models:$agentProfileId');
    return DesktopServiceResult<List<ModelProfileCatalogItem>>.success(
      modelAvailable
          ? const <ModelProfileCatalogItem>[
              ModelProfileCatalogItem(
                modelProfileId: 'model-public-1',
                displayName: '标准模型',
              ),
            ]
          : const <ModelProfileCatalogItem>[],
    );
  }

  @override
  Future<DesktopServiceResult<SharedSkillInstallationList>> loadInstallations(
    String workspaceId,
  ) async {
    operations.add('installations:$workspaceId');
    return DesktopServiceResult<SharedSkillInstallationList>.success(
      SharedSkillInstallationList(
        items: <SharedSkillInstallation>[
          SharedSkillInstallation(
            skillProfileId: 'viewpoint_germination',
            state: installationState,
            installMode: 'user_managed',
            installedAt: DateTime.utc(2026, 8, 1),
            updatedAt: DateTime.utc(2026, 8, 7),
          ),
        ],
      ),
    );
  }

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> createAgentRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) async {
    operations.add('create:${request.workspaceId}');
    createdRequests.add(request);
    idempotencyKeys.add(idempotencyKey);
    if (createFailureCount > 0) {
      createFailureCount -= 1;
      return const DesktopServiceResult<AgentRunSnapshot>.failure(
        code: 'TEST_CREATE_FAILED',
        message: '测试创建失败',
        retryable: true,
      );
    }
    return DesktopServiceResult<AgentRunSnapshot>.success(
      _fakeAgentRun(
        status: createStatus,
        completionMode: createStatus == 'succeeded'
            ? terminalCompletionMode
            : null,
        finalAnswer: finalAnswer,
        includeDurableResult: includeDurableResult,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> loadAgentRun(
    String agentRunId,
  ) async {
    operations.add('run:$agentRunId');
    if (pollFailureCount > 0) {
      pollFailureCount -= 1;
      return const DesktopServiceResult<AgentRunSnapshot>.failure(
        code: 'TEST_POLL_FAILED',
        message: '测试轮询失败',
        retryable: true,
      );
    }
    return DesktopServiceResult<AgentRunSnapshot>.success(
      _fakeAgentRun(
        status: terminalStatus,
        completionMode: terminalCompletionMode,
        finalAnswer: finalAnswer,
        includeDurableResult: includeDurableResult,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> createNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String inputPart,
    required String inputPartRevisionId,
    required String targetPart,
    required String targetPartRevisionId,
    required String instruction,
    required String agentProfileId,
    required List<String> skillProfileIds,
    required String idempotencyKey,
  }) async {
    operations.add('file-agent-create:$workspaceId:$noteId');
    createdFileAgentRuns.add((
      workspaceId: workspaceId,
      noteId: noteId,
      inputPart: inputPart,
      inputPartRevisionId: inputPartRevisionId,
      targetPart: targetPart,
      targetPartRevisionId: targetPartRevisionId,
      instruction: instruction,
      agentProfileId: agentProfileId,
      skillProfileIds: List<String>.unmodifiable(skillProfileIds),
    ));
    idempotencyKeys.add(idempotencyKey);
    if (createFailureCount > 0) {
      createFailureCount -= 1;
      return const DesktopServiceResult<DesktopNoteFileAgentRun>.failure(
        code: 'TEST_CREATE_FAILED',
        message: '测试创建失败',
        retryable: true,
      );
    }
    return DesktopServiceResult<DesktopNoteFileAgentRun>.success(
      _fakeNoteFileAgentRun(
        status: createStatus,
        noteId: noteId,
        inputPartRevisionId: inputPartRevisionId,
        targetPartRevisionId: targetPartRevisionId,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> loadNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  }) async {
    operations.add('file-agent-run:$fileAgentRunId');
    if (pollFailureCount > 0) {
      pollFailureCount -= 1;
      return const DesktopServiceResult<DesktopNoteFileAgentRun>.failure(
        code: 'TEST_POLL_FAILED',
        message: '测试轮询失败',
        retryable: true,
      );
    }
    final request = createdFileAgentRuns.last;
    return DesktopServiceResult<DesktopNoteFileAgentRun>.success(
      _fakeNoteFileAgentRun(
        status: terminalStatus,
        noteId: noteId,
        inputPartRevisionId: request.inputPartRevisionId,
        targetPartRevisionId: request.targetPartRevisionId,
      ),
    );
  }
}

DesktopNoteFileAgentRun _fakeNoteFileAgentRun({
  required String status,
  required String noteId,
  required String inputPartRevisionId,
  required String targetPartRevisionId,
}) => DesktopNoteFileAgentRun(
  fileAgentRunId: 'file-agent-run-1',
  noteId: noteId,
  status: status,
  agentProfileId: 'faya_germination',
  skillProfileIds: const <String>['viewpoint_germination'],
  inputPart: 'raw',
  inputPartRevisionId: inputPartRevisionId,
  targetPart: 'germination',
  targetPartRevisionId: targetPartRevisionId,
  agentRunId: 'agent-run-file-1',
  outputPartRevisionId: status == 'succeeded'
      ? 'germination-revision-output'
      : null,
  failureCode: status == 'failed' ? 'TEST_FILE_AGENT_FAILED' : null,
);

final class FakeDesktopBookWorkPort implements DesktopBookWorkPort {
  FakeDesktopBookWorkPort() {
    book = _fakeBook();
    works = <SharedWork>[_fakeWork()];
  }

  late SharedBook book;
  late List<SharedWork> works;
  bool unavailable = false;
  bool repeatWorkCursor = false;
  bool conflictingDuplicateWork = false;
  int loadBookFailureCount = 0;
  int loadWorksFailureCount = 0;
  int completeFailureCount = 0;
  int promoteFailureCount = 0;
  final List<String> operations = <String>[];
  final List<String> idempotencyKeys = <String>[];
  final List<String> etags = <String>[];
  String? lastBookPartRevisionId;
  String? lastWorkPartRevisionId;
  SharedPromoteWorkRequest? lastPromotionRequest;
  Completer<void>? loadBookGate;
  Completer<void>? completeGate;

  @override
  Future<DesktopServiceResult<SharedBook>> loadBook(String workspaceId) async {
    operations.add('book:$workspaceId');
    await loadBookGate?.future;
    if (unavailable) return _unavailable();
    if (loadBookFailureCount > 0) {
      loadBookFailureCount -= 1;
      return const DesktopServiceResult<SharedBook>.failure(
        code: 'TEST_BOOK_FAILED',
        message: '测试典藏读取失败',
        retryable: true,
      );
    }
    return DesktopServiceResult<SharedBook>.success(book);
  }

  @override
  Future<DesktopServiceResult<SharedWorkPage>> loadWorks(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) async {
    operations.add('works:$workspaceId:${cursor ?? 'first'}:${limit ?? 0}');
    if (unavailable) return _unavailable();
    if (loadWorksFailureCount > 0) {
      loadWorksFailureCount -= 1;
      return const DesktopServiceResult<SharedWorkPage>.failure(
        code: 'TEST_WORKS_FAILED',
        message: '测试创作历史读取失败',
        retryable: true,
      );
    }
    if (repeatWorkCursor) {
      return DesktopServiceResult<SharedWorkPage>.success(
        SharedWorkPage(
          items: cursor == null ? works : const <SharedWork>[],
          nextCursor: 'repeated-cursor',
        ),
      );
    }
    if (conflictingDuplicateWork) {
      return DesktopServiceResult<SharedWorkPage>.success(
        SharedWorkPage(
          items: cursor == null
              ? works
              : <SharedWork>[
                  _fakeWork(
                    workId: works.first.workId,
                    etag: '"conflicting-work"',
                  ),
                ],
          nextCursor: cursor == null ? 'duplicate-page' : null,
        ),
      );
    }
    return DesktopServiceResult<SharedWorkPage>.success(
      SharedWorkPage(items: works),
    );
  }

  @override
  Future<DesktopServiceResult<SharedWork>> loadWork(
    String workspaceId,
    String workId,
  ) async {
    operations.add('work:$workspaceId:$workId');
    if (unavailable) return _unavailable();
    return DesktopServiceResult<SharedWork>.success(
      works.firstWhere((work) => work.workId == workId),
    );
  }

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('book-part:$workspaceId:$sectionKey:$part');
    lastBookPartRevisionId = partRevisionId;
    if (unavailable) return _unavailable();
    return DesktopServiceResult<SharedManagedPartRevision>.success(
      _fakeManagedPart(part: part, revisionId: partRevisionId),
    );
  }

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadWorkPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('work-part:$workspaceId:$workId:$part');
    lastWorkPartRevisionId = partRevisionId;
    if (unavailable) return _unavailable();
    return DesktopServiceResult<SharedManagedPartRevision>.success(
      _fakeManagedPart(part: part, revisionId: partRevisionId),
    );
  }

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async {
    operations.add('complete:$workspaceId:$workId');
    etags.add(etag);
    idempotencyKeys.add(idempotencyKey);
    await completeGate?.future;
    if (completeFailureCount > 0) {
      completeFailureCount -= 1;
      return const DesktopServiceResult<SharedWorkspaceContentEvent>.failure(
        code: 'HTTP_412',
        message: '测试版本冲突',
      );
    }
    return DesktopServiceResult<SharedWorkspaceContentEvent>.success(
      _fakeBookWorkReceipt(workspaceId: workspaceId, workId: workId),
    );
  }

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async {
    operations.add('promote:$workspaceId:$workId');
    etags.add(etag);
    idempotencyKeys.add(idempotencyKey);
    lastPromotionRequest = request;
    if (promoteFailureCount > 0) {
      promoteFailureCount -= 1;
      return const DesktopServiceResult<SharedWorkspaceContentEvent>.failure(
        code: 'TEST_PROMOTE_FAILED',
        message: '测试收录失败',
        retryable: true,
      );
    }
    return DesktopServiceResult<SharedWorkspaceContentEvent>.success(
      _fakeBookWorkReceipt(workspaceId: workspaceId, workId: workId),
    );
  }

  DesktopServiceResult<T> _unavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'TEST_BOOK_WORK_UNAVAILABLE',
        message: '测试服务不可用',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SharedBook _fakeBook() {
  final sections = <SharedBookSection>[
    const SharedBookSection(
      sectionKey: 'preface',
      title: '写在前面',
      group: 'front_matter',
      ordinal: 0,
      metadataVersion: 1,
      currentPartRevisionIds: <String, String>{'raw': 'book-preface-raw-1'},
      parts: <SharedManagedPartHead>[
        SharedManagedPartHead(
          part: 'raw',
          status: 'ready',
          currentRevisionId: 'book-preface-raw-1',
          revision: 1,
        ),
      ],
      sourceRefs: <SharedManagedLineageRef>[],
      resourceRefs: <SharedManagedResourceRef>[],
      etag: '"book-section-preface-1"',
    ),
    const SharedBookSection(
      sectionKey: 'chapter_1',
      title: '第一章',
      group: 'chapters',
      ordinal: 0,
      metadataVersion: 1,
      currentPartRevisionIds: <String, String>{'raw': 'book-chapter-raw-1'},
      parts: <SharedManagedPartHead>[
        SharedManagedPartHead(
          part: 'raw',
          status: 'ready',
          currentRevisionId: 'book-chapter-raw-1',
          revision: 1,
        ),
      ],
      sourceRefs: <SharedManagedLineageRef>[],
      resourceRefs: <SharedManagedResourceRef>[],
      etag: '"book-section-chapter-1"',
    ),
  ];
  final snapshots = <SharedBookSectionSnapshot>[
    for (final section in sections)
      SharedBookSectionSnapshot(
        sectionKey: section.sectionKey,
        title: section.title,
        group: section.group,
        ordinal: section.ordinal,
        metadataVersion: section.metadataVersion,
        currentPartRevisionIds: section.currentPartRevisionIds,
      ),
  ];
  return SharedBook(
    bookId: 'book-test',
    currentBookRevisionId: 'book-revision-1',
    current: SharedBookRevision(
      bookRevisionId: 'book-revision-1',
      revision: 1,
      title: '我的典藏长文',
      language: 'zh-CN',
      status: 'draft',
      sectionOrderVersion: 1,
      sections: snapshots,
      createdAt: DateTime.utc(2026, 8, 7),
    ),
    sections: sections,
    etag: '"book-1"',
  );
}

SharedWork _fakeWork({
  String workId = 'work-test',
  String title = '一次完整创作',
  String lifecycle = 'active',
  String etag = '"work-1"',
}) => SharedWork(
  workId: workId,
  title: title,
  lifecycle: lifecycle,
  metadataVersion: 1,
  lineageRefs: const <SharedWorkLineageRef>[],
  resourceRefs: const <SharedManagedResourceRef>[],
  parts: const <SharedManagedPartHead>[
    SharedManagedPartHead(
      part: 'raw',
      status: 'ready',
      currentRevisionId: 'work-raw-1',
      revision: 1,
    ),
    SharedManagedPartHead(
      part: 'outline',
      status: 'ready',
      currentRevisionId: 'work-outline-1',
      revision: 1,
    ),
  ],
  etag: etag,
);

SharedManagedPartRevision _fakeManagedPart({
  required String part,
  required String revisionId,
}) => SharedManagedPartRevision(
  part: part,
  partRevisionId: revisionId,
  revision: 1,
  contentMarkdown: '# 精确内容\n\n来自 $revisionId。',
  contentHash: 'hash-$revisionId',
  sizeBytes: 24,
  sourceRefs: const <SharedNotePartSourceRef>[],
  createdAt: DateTime.utc(2026, 8, 7),
  etag: '"$revisionId"',
);

SharedWorkspaceContentEvent _fakeBookWorkReceipt({
  required String workspaceId,
  required String workId,
}) => SharedWorkspaceContentEvent(
  eventId: 'event-$workId',
  workspaceId: workspaceId,
  cursor: '2',
  operationId: 'operation-$workId',
  occurredAt: DateTime.utc(2026, 8, 7),
  objectKind: 'work',
  objectId: workId,
  changeType: 'updated',
  tombstone: false,
  resourcePinDelta: const SharedWorkspaceResourcePinDelta(
    added: <String>[],
    released: <String>[],
  ),
  version: 2,
);

AgentRunSnapshot _fakeAgentRun({
  required String status,
  String? completionMode,
  required String finalAnswer,
  bool includeDurableResult = true,
}) {
  final durable =
      status == 'succeeded' && completionMode != null && includeDurableResult;
  return AgentRunSnapshot(
    agentRunId: 'agent-run-desktop-1',
    workspaceId: 'workspace-test',
    status: status,
    workspaceVersion: 1,
    workspaceBindingVersion: 1,
    contextGeneration: 1,
    assistantMessageId: durable ? 'assistant-message-desktop-1' : null,
    completionMode: completionMode,
    result: durable
        ? AgentRunResult(
            finalAnswer: finalAnswer,
            assistantMessageId: 'assistant-message-desktop-1',
            completionMode: completionMode,
          )
        : null,
    usage: const AgentRunUsage(
      measurementStatus: 'measured',
      inputTokens: 40,
      outputTokens: 80,
      imageCount: 0,
      videoSeconds: 0,
      accountedCredits: 1,
      policyVersion: 'policy-test-1',
    ),
    toolTrace: const <AgentRunToolTrace>[],
    createdAt: DateTime.utc(2026, 8, 7, 8),
    updatedAt: DateTime.utc(2026, 8, 7, 8, 1),
  );
}

final class FakeDesktopSubscriptionPort implements DesktopSubscriptionPort {
  FakeDesktopSubscriptionPort()
    : publications = <SharedSubscriptionPublication>[
        _publication('publication-industry', '行业研究周报', 2),
        _publication('publication-customer', '客户访谈原文', 1),
        _publication('publication-creator', '创作者案例库', 1),
        _publication('publication-launch', '产品发布资料', 1),
        _publication('publication-city', '城市漫游', 1),
        _publication('publication-bookshop', '独立书店', 1),
        _publication('publication-museum', '博物馆知识', 1),
      ],
      articles = <SharedSubscriptionArticle>[
        _article(
          'industry-weekly',
          'publication-industry',
          '行业研究周报',
          '本周内容行业的渠道变化、平台规则和可复用案例摘要。',
          '内容研究共创组',
        ),
        _article(
          'industry-history',
          'publication-industry',
          '内容行业十年变化',
          '回看内容行业的关键变化。',
          '内容研究共创组',
        ),
        _article(
          'customer-interview',
          'publication-customer',
          '客户访谈原文',
          '围绕购买动机、真实阻碍和替代方案整理的访谈原话。',
          '用户声音计划',
        ),
        _article(
          'creator-cases',
          'publication-creator',
          '创作者案例库',
          '来自创作者社区的选题、表达方式与数据复盘。',
          '创作者案例共创组',
        ),
        _article(
          'launch-material',
          'publication-launch',
          '产品发布资料',
          '产品定位、发布节奏和原始视觉资料的集合。',
          '产品叙事档案',
        ),
        _article(
          'city-walks',
          'publication-city',
          '城市漫游里的日常观察',
          '从街区、空间与日常细节中提炼可写作的感受和观察。',
          '城市观察共创组',
        ),
        _article(
          'bookshop-notes',
          'publication-bookshop',
          '独立书店的选书方法',
          '书店经营者如何建立选书判断，以及它如何影响内容品味。',
          '阅读与书店计划',
        ),
        _article(
          'museum-objects',
          'publication-museum',
          '一件器物如何讲述历史',
          '从器物、展陈和叙事结构中理解历史内容的表达方法。',
          '博物馆知识共创组',
        ),
      ];

  final List<SharedSubscriptionPublication> publications;
  final List<SharedSubscriptionArticle> articles;
  final Set<String> followedPublicationIds = <String>{
    'publication-customer',
    'publication-creator',
  };
  final List<String> operations = <String>[];
  final List<String> idempotencyKeys = <String>[];
  bool failNextMutation = false;
  String? readFailureCode;

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionPublication>>
  >
  loadPublications({String? cursor, int? limit}) async {
    operations.add('publications');
    final failure =
        _readFailure<SharedSubscriptionPage<SharedSubscriptionPublication>>();
    return failure ??
        DesktopServiceResult<
          SharedSubscriptionPage<SharedSubscriptionPublication>
        >.success(
          SharedSubscriptionPage<SharedSubscriptionPublication>(
            items: publications,
          ),
        );
  }

  @override
  Future<DesktopServiceResult<SharedSubscriptionPublication>> loadPublication(
    String publicationId,
  ) async => DesktopServiceResult<SharedSubscriptionPublication>.success(
    publications.firstWhere((item) => item.publicationId == publicationId),
  );

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionSection>>
  >
  loadSections(String publicationId, {String? cursor, int? limit}) async =>
      const DesktopServiceResult<
        SharedSubscriptionPage<SharedSubscriptionSection>
      >.success(SharedSubscriptionPage<SharedSubscriptionSection>(items: []));

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionArticle>>
  >
  loadArticles({
    required String publicationId,
    String? sectionId,
    String? cursor,
    int? limit,
  }) async {
    operations.add('articles:$publicationId');
    return DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticle>
    >.success(
      SharedSubscriptionPage<SharedSubscriptionArticle>(
        items: articles
            .where((item) => item.publicationId == publicationId)
            .toList(growable: false),
      ),
    );
  }

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>> loadArticle(
    String articleId,
  ) async {
    operations.add('article:$articleId');
    final article = articles.firstWhere((item) => item.articleId == articleId);
    return DesktopServiceResult<SharedSubscriptionArticleRevision>.success(
      _revision(article),
    );
  }

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>
    >
  >
  loadArticleRevisions(String articleId, {String? cursor, int? limit}) async {
    final article = articles.firstWhere((item) => item.articleId == articleId);
    return DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>
    >.success(
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>(
        items: <SharedSubscriptionArticleRevision>[_revision(article)],
      ),
    );
  }

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>>
  loadArticleRevision(String articleId, String articleRevisionId) =>
      loadArticle(articleId);

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>
    >
  >
  loadLibrary(String workspaceId, {String? cursor, int? limit}) async {
    operations.add('library');
    return DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>
    >.success(
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>(
        items: publications
            .where(
              (item) => followedPublicationIds.contains(item.publicationId),
            )
            .map(
              (item) => SharedSubscriptionLibraryPublication(
                publication: item,
                followedAt: DateTime.utc(2026, 8, 1),
                availability: 'available',
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  followPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _mutateFollow(
    workspaceId,
    publicationId,
    idempotencyKey,
    following: true,
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  unfollowPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _mutateFollow(
    workspaceId,
    publicationId,
    idempotencyKey,
    following: false,
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionSaveReceipt>> saveArticleAsNote(
    String workspaceId,
    String articleId, {
    required String articleRevisionId,
    required String idempotencyKey,
  }) async {
    operations.add('save:$articleId');
    idempotencyKeys.add(idempotencyKey);
    return DesktopServiceResult<SharedSubscriptionSaveReceipt>.success(
      SharedSubscriptionSaveReceipt(
        noteId: 'note-$articleId',
        noteRevisionId: 'note-revision-$articleId',
        rawPartRevisionId: 'raw-$articleId',
        outlinePartRevisionId: 'outline-$articleId',
        germinationPartRevisionId: 'germination-$articleId',
        articleId: articleId,
        articleRevisionId: articleRevisionId,
        created: true,
        etag: '"note-$articleId"',
        contentCursor: '9',
      ),
    );
  }

  Future<DesktopServiceResult<SharedSubscriptionFollowResult>> _mutateFollow(
    String workspaceId,
    String publicationId,
    String idempotencyKey, {
    required bool following,
  }) async {
    operations.add('${following ? 'follow' : 'unfollow'}:$publicationId');
    idempotencyKeys.add(idempotencyKey);
    if (failNextMutation) {
      failNextMutation = false;
      return const DesktopServiceResult<SharedSubscriptionFollowResult>.failure(
        code: 'SUBSCRIPTION_MUTATION_FAILED',
        message: '订阅更新失败',
      );
    }
    if (following) {
      followedPublicationIds.add(publicationId);
    } else {
      followedPublicationIds.remove(publicationId);
    }
    return DesktopServiceResult<SharedSubscriptionFollowResult>.success(
      SharedSubscriptionFollowResult(
        workspaceId: workspaceId,
        publicationId: publicationId,
        lifecycle: following ? 'following' : 'unfollowed',
        followedAt: following ? DateTime.utc(2026, 8, 7) : null,
        unfollowedAt: following ? null : DateTime.utc(2026, 8, 7),
      ),
    );
  }

  DesktopServiceResult<T>? _readFailure<T>() {
    final code = readFailureCode;
    if (code == null) return null;
    return DesktopServiceResult<T>.failure(code: code, message: '订阅目录读取失败');
  }

  static SharedSubscriptionPublication _publication(
    String id,
    String title,
    int articleCount,
  ) => SharedSubscriptionPublication(
    publicationId: id,
    title: title,
    summary: '$title 的公开订阅内容',
    sectionCount: 0,
    articleCount: articleCount,
    updatedAt: DateTime.utc(2026, 8, 7),
  );

  static SharedSubscriptionArticle _article(
    String id,
    String publicationId,
    String title,
    String summary,
    String author,
  ) => SharedSubscriptionArticle(
    articleId: id,
    publicationId: publicationId,
    currentArticleRevisionId: 'revision-$id',
    title: title,
    summary: summary,
    author: author,
    publishedAt: DateTime.utc(2026, 8, 7),
  );

  static SharedSubscriptionArticleRevision _revision(
    SharedSubscriptionArticle article,
  ) => SharedSubscriptionArticleRevision(
    articleId: article.articleId,
    articleRevisionId: article.currentArticleRevisionId,
    title: article.title,
    contentMarkdown: '# ${article.title}\n\n${article.summary}',
    assetRefs: const <SharedSubscriptionArticleAssetRef>[],
    contentSha256: 'sha256-${article.articleId}',
  );
}

final class FakeDesktopWorkspacePort implements DesktopWorkspacePort {
  final List<String> operations = <String>[];
  final List<String> searchQueries = <String>[];
  final List<String> relationIdempotencyKeys = <String>[];
  final List<String> relationEtags = <String>[];
  final List<String> loadedNoteRevisionIds = <String>[];
  final List<String> loadedPartRevisionIds = <String>[];
  final List<SharedNoteRelation> relationItems = <SharedNoteRelation>[];
  Future<DesktopServiceResult<SharedWorkspaceSearchOutput>> Function(
    String query,
    int requestIndex,
  )?
  searchResponder;
  DesktopServiceResult<SharedWorkspaceSearchOutput>? searchResult;
  DesktopServiceResult<SharedHNote>? noteResult;
  DesktopServiceResult<SharedHNotePartView>? notePartResult;
  String? relationReadFailureCode;
  bool failNextRelationMutation = false;

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentSnapshot(
    String workspaceId,
  ) async => DesktopServiceResult<ApiContractObject>.success(
    ApiContractObject(<String, Object?>{'workspaceId': workspaceId}),
  );

  @override
  Future<DesktopServiceResult<ApiContractPage>> loadFolders(
    String workspaceId,
  ) async => const DesktopServiceResult<ApiContractPage>.success(
    ApiContractPage(items: <ApiContractObject>[]),
  );

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentNavigation(
    String workspaceId, {
    String map = 'overview',
  }) async {
    operations.add('navigation:$map');
    return DesktopServiceResult<ApiContractObject>.success(
      ApiContractObject(<String, Object?>{
        'workspaceId': workspaceId,
        'map': map,
      }),
    );
  }

  @override
  Future<DesktopServiceResult<SharedWorkspaceSearchOutput>> searchWorkspace(
    String workspaceId,
    SharedWorkspaceSearchRequest request,
  ) async {
    operations.add('search:${request.query}');
    searchQueries.add(request.query);
    final responder = searchResponder;
    if (responder != null) {
      return responder(request.query, searchQueries.length - 1);
    }
    return searchResult ??
        DesktopServiceResult<SharedWorkspaceSearchOutput>.success(
          _fakeWorkspaceSearchOutput(),
        );
  }

  @override
  Future<DesktopServiceResult<SharedHNote>> loadNote(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) async {
    operations.add('note:$noteId:$revisionId');
    loadedNoteRevisionIds.add(revisionId);
    return noteResult ??
        DesktopServiceResult<SharedHNote>.success(
          _fakeHNote(
            workspaceId: workspaceId,
            noteId: noteId,
            revisionId: revisionId,
          ),
        );
  }

  @override
  Future<DesktopServiceResult<SharedHNotePartView>> loadNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('part:$noteId:$part:$partRevisionId');
    loadedPartRevisionIds.add(partRevisionId);
    return notePartResult ??
        DesktopServiceResult<SharedHNotePartView>.success(
          SharedHNotePartView(
            noteId: noteId,
            part: part,
            partRevisionId: partRevisionId,
            markdown: '# 云端精确版本\n\n$partRevisionId',
            contentHash: 'hash-$partRevisionId',
            etag: '"$partRevisionId"',
          ),
        );
  }

  @override
  Future<DesktopServiceResult<SharedNoteRelationPage>> loadNoteRelations(
    String workspaceId,
    String noteId, {
    String? cursor,
    int? limit,
  }) async {
    operations.add('relations:$noteId:${cursor ?? ''}:${limit ?? ''}');
    final failureCode = relationReadFailureCode;
    if (failureCode != null) {
      return DesktopServiceResult<SharedNoteRelationPage>.failure(
        code: failureCode,
        message: '关系读取失败',
      );
    }
    return DesktopServiceResult<SharedNoteRelationPage>.success(
      SharedNoteRelationPage(items: List<SharedNoteRelation>.of(relationItems)),
    );
  }

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createNoteRelation(
    String workspaceId,
    String noteId,
    SharedCreateExplicitNoteRelationRequest request, {
    required String idempotencyKey,
  }) async => _relationMutation(
    workspaceId: workspaceId,
    relationId: 'created-relation',
    operation: 'create',
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateNoteRelation(
    String workspaceId,
    String relationId,
    SharedUpdateExplicitNoteRelationRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _relationMutation(
    workspaceId: workspaceId,
    relationId: relationId,
    operation: 'update',
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteNoteRelation(
    String workspaceId,
    String relationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _relationMutation(
    workspaceId: workspaceId,
    relationId: relationId,
    operation: 'delete',
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> _relationMutation({
    required String workspaceId,
    required String relationId,
    required String operation,
    required String idempotencyKey,
    String? etag,
  }) async {
    operations.add('$operation:$relationId');
    relationIdempotencyKeys.add(idempotencyKey);
    if (etag != null) relationEtags.add(etag);
    if (failNextRelationMutation) {
      failNextRelationMutation = false;
      return const DesktopServiceResult<SharedWorkspaceContentEvent>.failure(
        code: 'PRECONDITION_FAILED',
        message: '关系版本已变化',
      );
    }
    if (operation == 'delete') {
      relationItems.removeWhere((item) => item.relationId == relationId);
    }
    return DesktopServiceResult<SharedWorkspaceContentEvent>.success(
      _fakeRelationReceipt(
        workspaceId: workspaceId,
        relationId: relationId,
        tombstone: operation == 'delete',
      ),
    );
  }
}

final class FakeDesktopAccountUsagePort implements DesktopAccountUsagePort {
  DesktopServiceResult<SharedAccountMembershipResponse> membershipResult =
      DesktopServiceResult<SharedAccountMembershipResponse>.success(
        _fakeMembership(),
      );
  DesktopServiceResult<SharedAccountCreditSummary> creditsResult =
      DesktopServiceResult<SharedAccountCreditSummary>.success(_fakeCredits());
  final Map<String, DesktopServiceResult<SharedRunUsage>> runUsageResults =
      <String, DesktopServiceResult<SharedRunUsage>>{};
  final List<String> operations = <String>[];

  @override
  Future<DesktopServiceResult<SharedAccountMembershipResponse>>
  loadMembership() async {
    operations.add('membership');
    return membershipResult;
  }

  @override
  Future<DesktopServiceResult<SharedAccountCreditSummary>> loadCredits({
    String? cursor,
    int? limit,
  }) async {
    operations.add('credits:${cursor ?? ''}:${limit ?? ''}');
    return creditsResult;
  }

  @override
  Future<DesktopServiceResult<SharedRunUsage>> loadRunUsage(
    String runId,
  ) async {
    operations.add('usage:$runId');
    return runUsageResults[runId] ??
        DesktopServiceResult<SharedRunUsage>.success(_fakeRunUsage(runId));
  }
}

SharedWorkspaceSearchOutput _fakeWorkspaceSearchOutput({
  List<SharedWorkspaceSearchResult> results =
      const <SharedWorkspaceSearchResult>[],
}) => SharedWorkspaceSearchOutput(
  mode: 'keyword',
  queryFingerprint: 'query-fingerprint',
  keywordReadiness: 'current',
  vectorReadiness: 'unavailable',
  contentCursor: '1',
  results: results,
);

SharedHNote _fakeHNote({
  required String workspaceId,
  required String noteId,
  required String revisionId,
}) => SharedHNote(
  noteId: noteId,
  workspaceId: workspaceId,
  folderId: null,
  title: '云端精确笔记',
  state: 'active',
  noteRevisionId: revisionId,
  raw: const SharedHNotePart(
    partRevisionId: 'part-raw-exact',
    markdown: '# 云端精确版本\n',
    contentHash: 'hash-raw-exact',
  ),
  outline: const SharedHNotePart(
    partRevisionId: 'part-outline-exact',
    markdown: '## 精确纲要\n',
    contentHash: 'hash-outline-exact',
  ),
  germination: const SharedHNotePart(
    partRevisionId: 'part-germination-exact',
    markdown: '## 精确洞见\n',
    contentHash: 'hash-germination-exact',
  ),
  resourceRefs: const <SharedHNoteResourceRef>[],
  etag: '"$revisionId"',
  contentCursor: '1',
);

SharedWorkspaceContentEvent _fakeRelationReceipt({
  required String workspaceId,
  required String relationId,
  required bool tombstone,
}) => SharedWorkspaceContentEvent(
  eventId: 'event-$relationId',
  workspaceId: workspaceId,
  cursor: '2',
  operationId: 'operation-$relationId',
  occurredAt: DateTime.utc(2026, 8, 7),
  objectKind: 'note_relation',
  objectId: relationId,
  changeType: tombstone ? 'deleted' : 'updated',
  tombstone: tombstone,
  resourcePinDelta: const SharedWorkspaceResourcePinDelta(
    added: <String>[],
    released: <String>[],
  ),
  version: 2,
);

SharedAccountMembershipResponse _fakeMembership() =>
    SharedAccountMembershipResponse(
      membershipId: 'membership-test',
      levelCode: 'pilot_paid',
      status: 'active',
      expiresAt: null,
      monthlyCredit: _fakeMonthlyCredit(),
      permanentCredit: const SharedPermanentCredit(
        availableCredits: 800,
        reservedCredits: 0,
      ),
      account: const SharedAccountAdmission(
        runAdmission: 'allowed',
        outstandingUncoveredCredits: 0,
      ),
    );

SharedAccountCreditSummary _fakeCredits() => SharedAccountCreditSummary(
  monthlyCredit: _fakeMonthlyCredit(),
  permanentCredit: const SharedPermanentCreditPage(
    availableCredits: 800,
    reservedCredits: 0,
    lots: <SharedPermanentCreditLot>[],
  ),
  account: const SharedAccountAdmission(
    runAdmission: 'allowed',
    outstandingUncoveredCredits: 0,
  ),
);

SharedMonthlyCredit _fakeMonthlyCredit() => SharedMonthlyCredit(
  policyVersion: 'credit-policy-v1',
  quotaCredits: 10000000,
  periodStart: DateTime.utc(2026, 8, 1),
  periodEnd: DateTime.utc(2026, 9, 1),
  availableCredits: 9000000,
  reservedCredits: 1000,
  settledCredits: 999000,
  expiresAt: DateTime.utc(2026, 9, 1),
);

SharedRunUsage _fakeRunUsage(String runId) => SharedRunUsage(
  runId: runId,
  policyVersion: 'credit-policy-v1',
  rawInputTokens: 120,
  rawOutputTokens: 240,
  accountedCredits: 360,
  settlementStatus: 'settled',
  assistantResultPersisted: true,
  measurements: const <SharedRunUsageMeasurement>[],
);

final class FakeDesktopDocumentSyncPort implements DesktopDocumentSyncPort {
  final snapshots = <HuahuoDocumentSnapshot>[];
  final operations = <String>[];
  DesktopDocumentPullBatch pullBatch = const DesktopDocumentPullBatch(
    documents: <HuahuoDocumentSnapshot>[],
    deletedDocumentIds: <String>{},
    contentCursor: '0',
    rebuiltFromSnapshot: true,
    protectedPendingCount: 0,
  );
  bool failPull = false;
  String? userId;
  String? workspaceId;
  int remoteLocalRevision = 0;

  @override
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) async {
    operations.add('bind');
    this.userId = userId;
    this.workspaceId = workspaceId;
  }

  @override
  Future<void> clearAccount() async {
    operations.add('clear');
    userId = null;
    workspaceId = null;
  }

  @override
  Future<DesktopDocumentRemoteReference?> remoteReferenceFor({
    required String localDocumentId,
    String part = 'raw',
  }) async => DesktopDocumentRemoteReference(
    noteId: 'note-$localDocumentId',
    part: part,
    partRevisionId: '$part-revision',
    localRevision: remoteLocalRevision,
  );

  @override
  Future<DesktopServiceResult<DesktopDocumentPullBatch>> pullRemote({
    required DesktopDocumentPullApplier apply,
  }) async {
    operations.add('pull');
    if (failPull) {
      return const DesktopServiceResult<DesktopDocumentPullBatch>.failure(
        code: 'TEST_PULL_FAILED',
        message: '测试远端拉取失败',
      );
    }
    await apply(pullBatch);
    return DesktopServiceResult<DesktopDocumentPullBatch>.success(pullBatch);
  }

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> enqueue(
    HuahuoDocumentSnapshot snapshot,
  ) async {
    operations.add('enqueue');
    snapshots.add(snapshot);
    return const DesktopServiceResult<DesktopDocumentSyncState>.success(
      DesktopDocumentSyncState(
        phase: DesktopDocumentSyncPhase.synced,
        pendingCount: 0,
        serverRevision: 'test-revision',
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopDocumentSyncState>> retryPending() async {
    operations.add('flush');
    return const DesktopServiceResult<DesktopDocumentSyncState>.success(
      DesktopDocumentSyncState(
        phase: DesktopDocumentSyncPhase.synced,
        pendingCount: 0,
        serverRevision: 'test-revision',
      ),
    );
  }
}

final class FakeDesktopChatPort implements DesktopChatPort {
  FakeDesktopChatPort({
    this.agentRunId,
    DesktopChatThread? thread,
    DesktopChatThread? detailThread,
    Iterable<DesktopChatMessage> messages = const <DesktopChatMessage>[],
  }) : _thread = thread ?? defaultThread,
       _detailThread = detailThread ?? thread ?? defaultThread,
       _messages = List<DesktopChatMessage>.unmodifiable(messages);

  final String? agentRunId;
  static const defaultThread = DesktopChatThread(
    threadId: 'test-thread',
    title: '测试对话',
  );
  final DesktopChatThread _thread;
  final DesktopChatThread _detailThread;
  final List<DesktopChatMessage> _messages;

  List<DesktopChatContextReference> lastReferences =
      <DesktopChatContextReference>[];
  String? lastAgentProfileId;

  @override
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  }) async => DesktopServiceResult<DesktopChatThreadPage>.success(
    DesktopChatThreadPage(items: <DesktopChatThread>[_thread]),
  );

  @override
  Future<DesktopServiceResult<DesktopChatThread>> createThread() async =>
      DesktopServiceResult<DesktopChatThread>.success(_thread);

  @override
  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  ) async => DesktopServiceResult<DesktopChatThreadDetail>.success(
    DesktopChatThreadDetail(thread: _detailThread, messages: _messages),
  );

  @override
  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  }) async {
    lastReferences = references.toList(growable: false);
    lastAgentProfileId = agentProfileId;
    return DesktopServiceResult<DesktopChatReply>.success(
      DesktopChatReply(
        userMessage: DesktopChatMessage(
          messageId: 'test-user-message',
          threadId: threadId,
          role: 'user',
          text: content,
        ),
        assistantMessage: DesktopChatMessage(
          messageId: 'test-assistant-message',
          threadId: threadId,
          role: 'assistant',
          text: '围绕“$content”，先明确读者和结论，再按场景、冲突、判断组织素材。',
        ),
        agentRunId: agentRunId,
      ),
    );
  }
}
