import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/di/chat_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../shared/navigation/unsaved_changes_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../chat/application/chat_controller.dart';
import '../../chat/application/voice_message_controller.dart';
import '../../chat/domain/chat_context.dart';
import '../../chat/domain/chat_models.dart';
import '../../transcription/presentation/live_transcription_failure_dialog.dart';
import '../application/canvas_autosave_coordinator.dart';
import '../application/canvas_ai_controller.dart';
import '../application/canvas_ai_inline_review.dart';
import '../application/canvas_document_codec.dart';
import '../application/canvas_interaction_policy.dart';
import '../application/creation_canvas_history_port.dart';
import '../application/deep_positioning_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../application/knowledge_note_port.dart' show KnowledgeNoteSyncOutcome;
import '../application/profile_hub_controller.dart';
import '../application/script_draft_controller.dart';
import '../domain/canvas_ai_models.dart';
import '../domain/canvas_image_embed_data.dart';
import '../domain/creation_canvas_draft.dart';
import '../domain/creation_canvas_history.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/profile_activity_models.dart';
import '../domain/script_draft_models.dart';
import '../domain/ui_v3_models.dart';
import 'canvas_autosave_status.dart';
import 'v3_creation_canvas_chrome.dart';
import 'v3_creation_canvas_status_bars.dart';
import 'v3_knowledge_note_picker_sheet.dart';

const _openCanvasAiToolsForScreenshot = bool.fromEnvironment(
  'HUAHUO_CANVAS_OPEN_AI_TOOLS',
);
const _focusCanvasBodyForScreenshot = bool.fromEnvironment(
  'HUAHUO_CANVAS_FOCUS_BODY',
);
const _canvasChatUserInputLimit = 3600;
const _canvasChatTransportTextLimit = 4000;
const _canvasSheetDismissalDelay = V3InteractionTimingTokens.sheetDismissal;

class V3CreationCanvasPage extends ConsumerStatefulWidget {
  const V3CreationCanvasPage({
    required this.entryIntent,
    this.recoverySessionId,
    this.recoveryRunId,
    super.key,
  });

  final CanvasEntryIntent entryIntent;
  final String? recoverySessionId;
  final String? recoveryRunId;

  @override
  ConsumerState<V3CreationCanvasPage> createState() =>
      _V3CreationCanvasPageState();
}

class _V3CreationCanvasPageState extends ConsumerState<V3CreationCanvasPage>
    with RouteAware {
  static int _voiceSessionSequence = 0;

  late final TextEditingController _title;
  late final UndoHistoryController _titleUndo;
  late final TextEditingController _linkLabel;
  late final TextEditingController _linkUrl;
  late final VoiceMessageController _voiceController;
  late final QuillController _body;
  late final FocusNode _titleFocus;
  late final FocusNode _bodyFocus;
  late final ScrollController _canvasScroll;
  late final ScrollController _quillScroll;
  final ScrollController _bottomCommandScroll = ScrollController();
  final GlobalKey<EditorState> _bodyEditorKey = GlobalKey<EditorState>();
  late final CreationCanvasDraftStore _draftRepository;
  late final CanvasDraftPersistenceCoordinator _draftPersistence;
  DiagnosticLogger? _canvasLogger;
  late final CreationCanvasHistoryPort _historyPort;
  late final ScriptDraftController _scriptDraftController;
  late final String _historyUserScope;
  final CanvasDocumentCodec _documentCodec = CanvasDocumentCodec();
  BuildContext? _feedbackContext;
  final List<V3LinkedMaterialRef> _linkedMaterials = <V3LinkedMaterialRef>[];
  final Set<String> _ownedCanvasImageIds = <String>{};
  final Map<String, List<V3LinkedMaterialRef>> _linkedMaterialsByDocument =
      <String, List<V3LinkedMaterialRef>>{};

  StreamSubscription<DocChange>? _bodyChanges;
  late final CanvasAutosaveCoordinator _autosaveCoordinator;
  DateTime _draftCreatedAt = DateTime.now().toUtc();
  String? _sourceTopicId;
  String? _sourceTitle;
  String? _pendingSavedId;
  String? _boundAssetFingerprint;
  String? _chatThreadId;
  String? _entryIdentity;
  String _sessionId = _newCanvasSessionId();
  Object _leaveGuardIdentity = Object();
  final Object _canvasAiProviderOwner = Object();
  ScriptDraftGenerationReceipt? _scriptDraftReceipt;
  ProviderSubscription<ChatController>? _canvasChatSubscription;
  String? _bootstrapErrorMessage;
  _CanvasBootstrapPhase _bootstrapPhase = _CanvasBootstrapPhase.resolving;
  String? _selectedImageId;
  String _lastDocumentSignature = '';
  String _baselineSignature = '';
  bool _hydrating = true;
  bool _saving = false;
  bool _allowLeave = false;
  bool _leaveSettlementInProgress = false;
  bool _entryLoadFailed = false;
  bool _knowledgeRestoreFailed = false;
  bool _canvasChatStarted = false;
  bool _canvasChatFreshResetPending = false;
  bool _autosaveFailed = false;
  bool _savedDraftCleanupPending = false;
  bool _unreadableSessionMetadata = false;
  CreationCanvasHistoryCommitReceipt? _historyCommitReceipt;
  bool _draftClearInProgress = false;
  bool _draftPersistenceSuppressed = false;
  bool _draftRecoveryPresent = false;
  int _draftStateEpoch = 0;
  int _confirmedDraftStateEpoch = 0;
  bool _profileActivityRecorded = false;
  bool _automaticInitialNoteCreation = false;
  bool _automaticInitialNoteCreationScheduled = false;
  bool _editorRefreshScheduled = false;
  bool _caretRevealScheduled = false;
  bool _unreadableStructuredDraft = false;
  _CanvasEditorTarget _activeEditorTarget = _CanvasEditorTarget.body;
  _CanvasToolbarPanel _toolbarPanel = _CanvasToolbarPanel.none;
  CanvasAiEditScope _aiEditScope = CanvasAiEditScope.global;
  bool _linkEditorVisible = false;
  bool _linkEditingExisting = false;
  String? _linkError;
  int? _voiceInsertionOffset;
  int _voiceReplacementLength = 0;
  int _voiceInsertedLength = 0;
  String _lastVoiceTranscript = '';
  bool _ownsVoiceCapture = false;
  bool _voiceNoSpeech = false;
  late final String _voiceSessionOwner;
  final LiveTranscriptionFailureDialogGate _voiceFailureDialogGate =
      LiveTranscriptionFailureDialogGate();
  PageRoute<dynamic>? _observedRoute;
  bool _routeVisible = true;
  bool _routeVoiceCleanupScheduled = false;
  TextSelection? _frozenBodySelection;
  _CanvasAiRichTarget? _activeAiTarget;
  CanvasAiInlineReview? _inlineAiReview;
  String? _reviewRequestId;
  final FocusNode _reviewFocus = FocusNode(
    debugLabel: 'creation-canvas-review',
  );
  final ScrollController _reviewScroll = ScrollController();
  final GlobalKey<EditorState> _reviewEditorKey = GlobalKey<EditorState>();
  final Map<String, CreationCanvasChatRewriteReceipt> _chatRewriteReceipts =
      <String, CreationCanvasChatRewriteReceipt>{};
  _CanvasChatPendingRewriteTurn? _pendingChatRewriteTurn;
  int _initialGenerationEpoch = 0;
  ({
    CanvasEntryIntent intent,
    String? recoverySessionId,
    String? recoveryRunId,
  })?
  _pendingEntryIntent;
  bool _entryIntentTransitionScheduled = false;
  bool _entryIntentTransitionInProgress = false;
  bool _entryIntentTransitionFailed = false;
  bool _saveConfirmationOpen = false;
  bool _aiToolsSheetOpen = false;
  bool _moreActionsSheetOpen = false;
  bool _leaveDecisionOpen = false;
  int _documentRevision = 0;

  bool get _isDirty => _editorSignature != _baselineSignature;

  bool get _editingHistory => _historyIdentityFromEntry(_entryIdentity) != null;

  bool _isAutomaticAgentEntry(CanvasEntryIntent intent) =>
      intent is CanvasAssetEntryIntent &&
      intent.seed.initialSourceMode ==
          AssetCanvasInitialSourceMode.generateTranscript;

  String _canvasEntryIdentity(
    CanvasEntryIntent intent,
    ScriptDraftSourceSnapshot? source,
  ) {
    final identity = source?.identity ?? intent.stableSourceId;
    return _isAutomaticAgentEntry(intent) ? 'agent-note:$identity' : identity;
  }

  bool _isAutomaticAgentIdentity(String? identity) =>
      identity?.startsWith('agent-note:') == true;

  String get _documentJson => _documentCodec.encodeDocumentJson(_body.document);

  String get _documentSignature =>
      jsonEncode(_body.document.toDelta().toJson());

  String get _bodyMarkdown => _documentCodec.documentToMarkdown(_body.document);

  bool get _bodyIsEmpty => _body.document.toPlainText().trim().isEmpty;

  String get _editorSignature => _canvasEditorSnapshotSignature(
    title: _title.text,
    documentSignature: _lastDocumentSignature,
    sourceTopicId: _sourceTopicId,
    sourceTitle: _sourceTitle,
    linkedMaterials: _linkedMaterials,
  );

  @override
  void initState() {
    super.initState();
    _voiceSessionSequence += 1;
    _voiceSessionOwner =
        'canvas-${DateTime.now().microsecondsSinceEpoch}-$_voiceSessionSequence';
    _title = TextEditingController();
    _titleUndo = UndoHistoryController()..addListener(_scheduleEditorRefresh);
    _linkLabel = TextEditingController();
    _linkUrl = TextEditingController(text: 'https://');
    _voiceController = ref.read(feedAiVoiceMessageControllerProvider)
      ..addListener(_handleCanvasVoiceStateChanged);
    _body = QuillController.basic();
    _titleFocus = FocusNode(debugLabel: 'creation-canvas-title');
    _bodyFocus = FocusNode(debugLabel: 'creation-canvas-body');
    _canvasScroll = ScrollController()..addListener(_handleCanvasScroll);
    _quillScroll = ScrollController();
    _lastDocumentSignature = _documentSignature;
    _listenToBodyDocument();
    _draftRepository = ref.read(creationCanvasDraftRepositoryProvider);
    _draftPersistence = CanvasDraftPersistenceCoordinator(_draftRepository);
    try {
      _canvasLogger = ref.read(diagnosticLoggerProvider);
    } on Object {
      _canvasLogger = null;
    }
    _historyPort = ref.read(creationCanvasHistoryPortProvider);
    _historyUserScope = ref.read(authenticatedUserDataScopeProvider);
    _scriptDraftController = ScriptDraftController(
      ref.read(scriptDraftGenerationPortProvider),
      persistReceipt: _persistScriptDraftReceipt,
    )..addListener(_handleScriptDraftStateChanged);
    _autosaveCoordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () =>
          !_hydrating && !_saving && !_leaveSettlementInProgress,
      canScheduleCloudSync: () => false,
      canRunCloudSync: () => false,
      persist: _persistDraftDeferred,
      synchronize: () async {},
      cloudSyncDelay: Duration.zero,
    );
    ref.listenManual<AppVisibility>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.visibility,
      ),
      (previous, next) {
        if (next == AppVisibility.foreground ||
            previous != AppVisibility.foreground) {
          return;
        }
        if (_leaveSettlementInProgress) return;
        _autosaveCoordinator.cancelPersist();
        _persistDraft(notify: false);
        if (_ownsVoiceCapture) {
          _ownsVoiceCapture = false;
          unawaited(
            _voiceController.endCaptureForLeave(owner: _voiceSessionOwner),
          );
        }
      },
    );
    ref.listenManual<int>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.viewMetricsRevision,
      ),
      (_, __) => _scheduleCaretReveal(),
    );
    _title.addListener(_handleTitleChanged);
    _body.addListener(_handleBodyControllerChanged);
    _titleFocus.addListener(_handleEditorFocusChanged);
    _bodyFocus.addListener(_handleEditorFocusChanged);
    unawaited(_restoreInitialDraft());
    if (_openCanvasAiToolsForScreenshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _bodyFocus.requestFocus();
        unawaited(_showAiTools(allowEmpty: true));
      });
    }
    if (_focusCanvasBodyForScreenshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _bodyFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant V3CreationCanvasPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final recoveryChanged =
        oldWidget.recoverySessionId != widget.recoverySessionId ||
        oldWidget.recoveryRunId != widget.recoveryRunId;
    if (recoveryChanged) {
      if (widget.recoverySessionId == _sessionId &&
          (widget.recoveryRunId == null ||
              widget.recoveryRunId == _scriptDraftReceipt?.agentRunId)) {
        _pendingEntryIntent = null;
        _entryIntentTransitionFailed = false;
        return;
      }
      _queueEntryIntent(widget.entryIntent, recoverRoute: true);
      return;
    }
    if (_entryIntentTransitionIdentity(oldWidget.entryIntent) ==
        _entryIntentTransitionIdentity(widget.entryIntent)) {
      return;
    }
    _queueEntryIntent(widget.entryIntent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || identical(route, _observedRoute)) {
      return;
    }
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _observedRoute = route;
    _routeVisible = route.isCurrent;
    appRouteObserver.subscribe(this, route);
  }

  bool get _isInitialDraftBusy =>
      _bootstrapPhase == _CanvasBootstrapPhase.resolving ||
      _bootstrapPhase == _CanvasBootstrapPhase.awaitingDraftChoice ||
      _bootstrapPhase == _CanvasBootstrapPhase.generating;

  CanvasAiControllerScope get _canvasAiControllerScope =>
      CanvasAiControllerScope(
        owner: _canvasAiProviderOwner,
        sessionId: _sessionId,
      );

  CanvasAiController get _canvasAiController =>
      ref.read(canvasAiControllerProvider(_canvasAiControllerScope));

  CanvasEditingMode get _editingMode => _toolbarPanel == _CanvasToolbarPanel.ai
      ? CanvasEditingMode.ai
      : CanvasEditingMode.edit;

  CanvasInteractionPolicy get _interactionPolicy => CanvasInteractionPolicy(
    editingMode: _editingMode,
    isInitializing:
        _isInitialDraftBusy ||
        _bootstrapPhase == _CanvasBootstrapPhase.failed ||
        _unreadableSessionMetadata,
    isDirty:
        _isDirty ||
        _draftStateEpoch != _confirmedDraftStateEpoch ||
        (_draftRecoveryPresent && !_mustRetainCleanRecoveryDraft),
    hasBodyContent: !_bodyIsEmpty,
    isLinkEditing: _linkEditorVisible,
    aiStatus: _canvasAiController.status,
    isVoiceEngaged: _ownsVoiceCapture,
    hasPendingChat: _pendingChatRewriteTurn != null,
    hasPendingSaveReceipt:
        _historyCommitReceipt != null || _savedDraftCleanupPending,
    isSaving: _saving,
    isLeaveSettlementInProgress: _leaveSettlementInProgress,
    isEntryTransitionInProgress: _entryIntentTransitionInProgress,
    hasPersistedLocalDraft:
        (_draftRecoveryPresent &&
            _draftStateEpoch == _confirmedDraftStateEpoch &&
            !_autosaveFailed) ||
        _boundAssetLocallyVerified,
    localDraftWriteFailed: _autosaveFailed,
    cloudSaveVerified: _cloudSaveVerified,
    needsCloudSave: _boundAssetNeedsCloudSave,
    isBoundNote: _clean(_pendingSavedId) != null,
  );

  bool get _cloudSaveVerified {
    final savedId = _clean(_pendingSavedId);
    final fingerprint = _clean(_boundAssetFingerprint);
    if (savedId == null ||
        fingerprint == null ||
        _isDirty ||
        _historyCommitReceipt != null ||
        _savedDraftCleanupPending) {
      return false;
    }
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(savedId);
    return note != null &&
        note.syncState == NoteSyncState.synced &&
        _clean(note.remoteNoteId) != null &&
        _clean(note.rawPartRevisionId) != null &&
        _canvasBoundAssetFingerprint(note) == fingerprint;
  }

  bool get _boundAssetLocallyVerified =>
      _clean(_pendingSavedId) != null && _currentBoundAssetStillMatches();

  bool get _boundAssetNeedsCloudSave {
    final savedId = _clean(_pendingSavedId);
    if (savedId == null || !_boundAssetLocallyVerified) return false;
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(savedId);
    return note != null &&
        (note.syncState != NoteSyncState.synced ||
            _clean(note.remoteNoteId) == null ||
            _clean(note.rawPartRevisionId) == null);
  }

  bool get _leaveHardBlocked => _interactionPolicy.hardBlocksLeave;

  bool get _documentTransitionLocked =>
      _leaveHardBlocked || _interactionPolicy.isInitializing;

  bool get _baseInteractionLocked =>
      _documentTransitionLocked ||
      _ownsVoiceCapture ||
      _interactionPolicy.aiNeedsResolution;

  bool get _saveInteractionLocked => _interactionPolicy.locksSave;

  bool get _interactionLocked => _interactionPolicy.locksEditor;

  bool get _bodyCommandsAvailable =>
      _interactionPolicy.canUseEditorCommands &&
      _activeEditorTarget == _CanvasEditorTarget.body &&
      !_titleFocus.hasFocus &&
      !_linkEditorVisible;

  bool get _canStopCanvasVoice =>
      _ownsVoiceCapture &&
      _voiceState.isCaptureActive &&
      !_voiceState.isBusy &&
      !_documentTransitionLocked &&
      _historyCommitReceipt == null;

  bool get _hasPendingSave => _interactionPolicy.canSave;

  VoiceMessageState get _voiceState => _voiceController.state;

  bool get _voiceControlEngaged =>
      _ownsVoiceCapture && (_voiceState.isBusy || _voiceState.isCaptureActive);

  bool get _toolbarHasSecondaryRow =>
      _toolbarPanel != _CanvasToolbarPanel.none &&
      _toolbarPanel != _CanvasToolbarPanel.ai;

  double get _bottomCommandInset {
    final width = MediaQuery.sizeOf(context).width;
    final aiStatus = _canvasAiController.status;
    if (aiStatus == CanvasAiTransformStatus.previewing &&
        _inlineAiReview != null) {
      return width < 360 ? 260 : 224;
    }
    if (aiStatus == CanvasAiTransformStatus.failed ||
        aiStatus == CanvasAiTransformStatus.awaitingCompletion) {
      return 250;
    }
    if (_linkEditorVisible) return width < 360 ? 324 : 304;
    return _toolbarHasSecondaryRow ? 190 : 132;
  }

  Widget _buildMarkdownEditor(bool interactionLocked) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final bottomInset =
        _bottomCommandInset + MediaQuery.viewInsetsOf(context).bottom;
    _body.readOnly = interactionLocked;
    return LayoutBuilder(
      builder: (context, constraints) {
        final minimumBodyHeight = math.max(430.0, constraints.maxHeight - 82);
        return NotificationListener<UserScrollNotification>(
          onNotification: _preserveSelectedEditorFocus,
          child: ListView(
            key: const ValueKey<String>('canvas-editor-scroll'),
            controller: _canvasScroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(22, 8, 22, bottomInset),
            children: [
              KeyedSubtree(
                key: ValueKey<String>('canvas-title-session-$_sessionId'),
                child: TextField(
                  key: const ValueKey<String>('canvas-title-field'),
                  controller: _title,
                  undoController: _titleUndo,
                  focusNode: _titleFocus,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  readOnly:
                      interactionLocked ||
                      _editingHistory ||
                      _pendingSavedId != null,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _bodyFocus.requestFocus(),
                  maxLines: null,
                  decoration: const InputDecoration(
                    hintText: '标题',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: TextStyle(
                    color: tokens.ink,
                    fontSize: 17,
                    height: 1.3,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: tokens.line),
              const SizedBox(height: 18),
              Offstage(
                offstage: _inlineAiReview != null,
                child: _buildBodyEditor(
                  interactionLocked: interactionLocked,
                  minimumHeight: minimumBodyHeight,
                ),
              ),
              if (_inlineAiReview != null)
                Column(
                  key: const ValueKey<String>('canvas-ai-diff-preview'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      label: 'AI 改写建议已生成，请审核删除和新增内容。',
                      child: const SizedBox.shrink(),
                    ),
                    Semantics(
                      container: true,
                      explicitChildNodes: true,
                      label: '正文修改对比。删除内容使用红色删除线，新增内容使用绿色，未变化内容保持原样。审核内容不可编辑。',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 16,
                            runSpacing: 6,
                            children: [
                              _CanvasDiffLegend(
                                icon: Icons.remove_circle_outline_rounded,
                                label: '删除内容',
                                color: _canvasDeletedColor(context),
                                strikethrough: true,
                              ),
                              _CanvasDiffLegend(
                                icon: Icons.add_circle_outline_rounded,
                                label: '新增内容',
                                color: _canvasInsertedColor(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _buildBodyEditor(
                            interactionLocked: true,
                            reviewing: true,
                            minimumHeight: math.max(
                              430,
                              minimumBodyHeight - 44,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBodyEditor({
    required bool interactionLocked,
    required double minimumHeight,
    bool reviewing = false,
  }) {
    final editor = reviewing ? _inlineAiReview!.editor : _body;
    editor.readOnly = interactionLocked || reviewing;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumHeight),
      child: QuillEditor(
        key: ValueKey<String>(
          reviewing ? 'canvas-ai-inline-editor' : 'canvas-body-field',
        ),
        controller: editor,
        focusNode: reviewing ? _reviewFocus : _bodyFocus,
        scrollController: reviewing ? _reviewScroll : _quillScroll,
        config: QuillEditorConfig(
          scrollable: false,
          expands: false,
          padding: EdgeInsets.zero,
          placeholder: '开始写点什么...',
          textCapitalization: TextCapitalization.none,
          detectWordBoundary: false,
          scrollBottomInset: reviewing ? 0 : _bottomCommandInset,
          editorKey: reviewing ? _reviewEditorKey : _bodyEditorKey,
          customStyles: _canvasEditorStyles(context),
          // Quill's key hook is the only interception point before its built-in
          // formatting shortcuts mutate a read-only review controller.
          // ignore: experimental_member_use
          onKeyPressed: reviewing ? _handleReviewKeyPressed : null,
          customActions: reviewing
              ? <Type, Action<Intent>>{
                  CopySelectionTextIntent:
                      CallbackAction<CopySelectionTextIntent>(
                        onInvoke: (intent) {
                          if (!intent.collapseSelection) {
                            _copyInlineAiReviewSelection();
                          }
                          return null;
                        },
                      ),
                  PasteTextIntent: DoNothingAction(),
                  UndoTextIntent: DoNothingAction(),
                  RedoTextIntent: DoNothingAction(),
                }
              : null,
          customStyleBuilder: reviewing
              ? (attribute) {
                  final change = CanvasAiInlineReview.changeFor({
                    attribute.key: attribute.value,
                  });
                  if (change == null) return const TextStyle();
                  final deleted = change == CanvasReviewChange.deleted;
                  final color = deleted
                      ? _canvasDeletedColor(context)
                      : _canvasInsertedColor(context);
                  return TextStyle(
                    color: color,
                    backgroundColor: color.withValues(alpha: .10),
                    decoration: deleted ? TextDecoration.lineThrough : null,
                    decorationColor: color,
                    decorationThickness: deleted ? 2 : null,
                  );
                }
              : null,
          textSpanBuilder: reviewing
              ? _buildReviewTextSpan
              : defaultSpanBuilder,
          contextMenuBuilder: _buildBodyContextMenu,
          embedBuilders: <EmbedBuilder>[
            _CanvasDividerEmbedBuilder(reviewing: reviewing),
            _CanvasImageEmbedBuilder(
              reviewing: reviewing,
              selectedImageId: reviewing ? null : _selectedImageId,
              enabled: !interactionLocked && !reviewing,
              onSelected: _selectImage,
              onWidthChanged: _resizeImage,
            ),
          ],
          onTapOutsideEnabled: true,
          onTapOutside: (_, __) => _clearSelectedImage(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _routeVisible = false;
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _canvasChatSubscription?.close();
    _canvasChatSubscription = null;
    _scriptDraftController
      ..removeListener(_handleScriptDraftStateChanged)
      ..dispose();
    _autosaveCoordinator.dispose();
    if (!_allowLeave &&
        !_draftClearInProgress &&
        (_isDirty ||
            _savedDraftCleanupPending ||
            _historyCommitReceipt != null ||
            _chatThreadId != null ||
            _scriptDraftReceipt != null)) {
      _persistDraft(notify: false);
    }
    _title
      ..removeListener(_handleTitleChanged)
      ..dispose();
    _titleUndo
      ..removeListener(_scheduleEditorRefresh)
      ..dispose();
    _linkLabel.dispose();
    _linkUrl.dispose();
    _voiceController.removeListener(_handleCanvasVoiceStateChanged);
    if (_ownsVoiceCapture) {
      final controller = _voiceController;
      final owner = _voiceSessionOwner;
      unawaited(
        Future<void>.microtask(() async {
          await controller.endCaptureForLeave(owner: owner);
        }),
      );
    }
    unawaited(_bodyChanges?.cancel());
    _body
      ..removeListener(_handleBodyControllerChanged)
      ..dispose();
    _canvasScroll
      ..removeListener(_handleCanvasScroll)
      ..dispose();
    _quillScroll.dispose();
    _bottomCommandScroll.dispose();
    _titleFocus
      ..removeListener(_handleEditorFocusChanged)
      ..dispose();
    _bodyFocus
      ..removeListener(_handleEditorFocusChanged)
      ..dispose();
    _inlineAiReview?.dispose();
    _reviewFocus.dispose();
    _reviewScroll.dispose();
    super.dispose();
  }

  @override
  void didPush() {
    _routeVisible = true;
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _scheduleRouteVoiceCleanup();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _routeVoiceCleanupScheduled = false;
  }

  @override
  void didPop() {
    _routeVisible = false;
    _scheduleRouteVoiceCleanup();
  }

  void _scheduleRouteVoiceCleanup() {
    if (_routeVoiceCleanupScheduled) return;
    _routeVoiceCleanupScheduled = true;
    // RouteAware runs while Navigator owns its route lock, so controller
    // mutations wait for the next stable frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeVoiceCleanupScheduled = false;
      if (!mounted || _routeVisible || !_ownsVoiceCapture) return;
      _ownsVoiceCapture = false;
      unawaited(_voiceController.endCaptureForLeave(owner: _voiceSessionOwner));
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final ai = ref.watch(canvasAiControllerProvider(_canvasAiControllerScope));
    final voice = ref.watch(feedAiVoiceMessageControllerProvider).state;
    final media = MediaQuery.of(context);
    final tokens = HuahuoV3Theme.tokensOf(context);
    final bottomCommandSpacing = media.viewInsets.bottom > 0 ? 4.0 : 0.0;
    final bottomCommandMaxHeight = math.max(
      0.0,
      media.size.height -
          media.viewInsets.bottom -
          media.padding.top -
          media.padding.bottom -
          bottomCommandSpacing,
    );
    _schedulePendingEntryIntentTransition();
    final interactionLocked = _interactionLocked;
    final editorInteractionLocked = interactionLocked || _linkEditorVisible;
    return ScaffoldMessenger(
      child: Builder(
        builder: (feedbackContext) {
          _feedbackContext = feedbackContext;
          return UnsavedChangesGuard(
            key: ObjectKey(_leaveGuardIdentity),
            hasUnsavedChanges: _requiresLeaveSettlement,
            isLeaveBlocked: _leaveHardBlocked,
            fallbackRoute: AppRoutePaths.homeForMode(
              AppRoutePaths.workbenchMode,
            ),
            hasUnsavedChangesNow: () => _requiresLeaveSettlement,
            isLeaveBlockedNow: () => _leaveHardBlocked,
            onLeaveBlocked: _showInteractionLocked,
            onConfirmLeave: _confirmDiscardForLeave,
            onConfirmForegroundIngress: _confirmForegroundIngress,
            enableLeadingEdgeSwipeLeave: true,
            child: Builder(
              builder: (guardContext) => Scaffold(
                backgroundColor: tokens.canvas,
                extendBody: true,
                resizeToAvoidBottomInset: false,
                body: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      _buildCanvasTopBar(
                        guardContext: guardContext,
                        interactionLocked: editorInteractionLocked,
                      ),
                      if (_sourceTitle != null) _buildTopicContext(),
                      if (_pendingEntryIntent != null &&
                          !_entryIntentTransitionFailed)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text('新的任务入口正在等待安全切换，当前仍显示原任务。'),
                        ),
                      if (_entryIntentTransitionFailed ||
                          _autosaveFailed ||
                          _savedDraftCleanupPending ||
                          _historyCommitReceipt != null)
                        CanvasAutosaveFailureBar(
                          message: _entryIntentTransitionFailed
                              ? '当前草稿尚未安全保存，新的创作入口未打开'
                              : _historyCommitReceipt != null
                              ? switch (_historyCommitReceipt!.phase) {
                                  CreationCanvasHistoryCommitPhase.prepared =>
                                    '保存事务已准备，笔记写入尚待完成',
                                  CreationCanvasHistoryCommitPhase
                                      .noteCommitted =>
                                    '笔记已落盘，创作历史尚待提交',
                                  CreationCanvasHistoryCommitPhase
                                      .historyCommitted =>
                                    '创作历史已保留，等待云端保存确认',
                                }
                              : _savedDraftCleanupPending
                              ? '笔记已保存，本地草稿记录待清理'
                              : '草稿暂未自动保存',
                          actionLabel: _entryIntentTransitionFailed
                              ? '重试打开'
                              : _historyCommitReceipt != null
                              ? '继续提交'
                              : _savedDraftCleanupPending
                              ? '完成清理'
                              : '重试',
                          onRetry: () {
                            if (_entryIntentTransitionFailed) {
                              _retryPendingEntryIntentTransition();
                            } else if (_historyCommitReceipt != null) {
                              unawaited(_confirmAndSave());
                            } else if (_savedDraftCleanupPending) {
                              unawaited(_retrySavedDraftCleanup());
                            } else {
                              _persistDraft();
                            }
                          },
                        ),
                      if (_pendingChatRewriteTurn != null)
                        _buildPendingChatStatus(),
                      Expanded(
                        child: _bootstrapPhase == _CanvasBootstrapPhase.ready
                            ? _buildMarkdownEditor(editorInteractionLocked)
                            : _buildInitialDraftSurface(),
                      ),
                      if (_ownsVoiceCapture)
                        V3CanvasVoiceStatusBar(
                          state: voice,
                          noSpeech: _voiceNoSpeech,
                        ),
                    ],
                  ),
                ),
                floatingActionButton:
                    editorInteractionLocked ||
                        _bootstrapPhase != _CanvasBootstrapPhase.ready
                    ? null
                    : _CanvasFloatingChatEntry(
                        onPressed: _interactionPolicy.canOpenChat
                            ? () => unawaited(_openCanvasChat())
                            : _showInteractionLocked,
                      ),
                floatingActionButtonLocation:
                    FloatingActionButtonLocation.endFloat,
                bottomNavigationBar:
                    _bootstrapPhase != _CanvasBootstrapPhase.ready
                    ? null
                    : AnimatedPadding(
                        duration: V3MotionTokens.standard,
                        curve: Curves.easeOutCubic,
                        padding: EdgeInsets.only(
                          bottom: media.viewInsets.bottom,
                        ),
                        child: SafeArea(
                          top: false,
                          bottom: media.viewInsets.bottom == 0,
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: media.viewInsets.bottom > 0 ? 2 : 0,
                              bottom: media.viewInsets.bottom > 0 ? 2 : 0,
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: bottomCommandMaxHeight,
                              ),
                              child: SingleChildScrollView(
                                key: const ValueKey<String>(
                                  'canvas-bottom-command-scroll',
                                ),
                                controller: _bottomCommandScroll,
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.manual,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (ai.status ==
                                            CanvasAiTransformStatus
                                                .previewing &&
                                        _inlineAiReview != null)
                                      V3CanvasAiDiffDecisionBar(
                                        action: ai.request?.action,
                                        scope:
                                            ai.request?.editScope ??
                                            CanvasAiEditScope.global,
                                        insertedCharacters: _inlineAiReview!
                                            .insertedCharacterCount,
                                        deletedCharacters: _inlineAiReview!
                                            .deletedCharacterCount,
                                        onReject: _rejectAiPreview,
                                        onApply: _applyAiPreview,
                                      )
                                    else if (ai.status ==
                                            CanvasAiTransformStatus.failed ||
                                        ai.status ==
                                            CanvasAiTransformStatus
                                                .awaitingCompletion)
                                      _buildAiRecoverySheet(ai)
                                    else if (ai.status ==
                                        CanvasAiTransformStatus.running)
                                      V3CanvasAiRunningBar(
                                        action: ai.request?.action,
                                        onCancel: _cancelAiProposal,
                                      )
                                    else if (_linkEditorVisible)
                                      _buildInlineLinkEditor(
                                        interactionLocked,
                                        maxHeight: bottomCommandMaxHeight,
                                      )
                                    else
                                      AnimatedOpacity(
                                        duration: V3MotionTokens.responsive,
                                        opacity:
                                            interactionLocked &&
                                                !_canStopCanvasVoice
                                            ? .55
                                            : 1,
                                        child: _buildMarkdownToolbar(
                                          interactionLocked,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCanvasSnack(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = V3FeedbackTimingTokens.standardSnack,
  }) {
    final feedbackContext = _feedbackContext;
    showV3Snack(
      feedbackContext != null && feedbackContext.mounted
          ? feedbackContext
          : context,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  Widget _buildPendingChatStatus() {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      key: const ValueKey<String>('canvas-chat-pending-status'),
      decoration: BoxDecoration(
        color: tokens.surfaceMuted,
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.forum_outlined, size: 17, color: tokens.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '创作聊天正在处理，可继续编辑或保存；返回后会校验原版本',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HuahuoV3Theme.meta.copyWith(color: tokens.muted),
              ),
            ),
            TextButton(
              key: const ValueKey<String>('canvas-chat-pending-open'),
              onPressed: () => unawaited(_openCanvasChat()),
              child: const Text('查看'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvasTopBar({
    required BuildContext guardContext,
    required bool interactionLocked,
  }) {
    final policy = _interactionPolicy;
    final canUndo =
        !interactionLocked &&
        _inlineAiReview == null &&
        (_activeEditorTarget == _CanvasEditorTarget.title
            ? _titleUndo.value.canUndo
            : _body.hasUndo);
    final canRedo =
        !interactionLocked &&
        _inlineAiReview == null &&
        (_activeEditorTarget == _CanvasEditorTarget.title
            ? _titleUndo.value.canRedo
            : _body.hasRedo);
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 8),
        child: Row(
          children: [
            V3NavigationBackButton(
              onPressed: () =>
                  unawaited(UnsavedChangesGuard.requestLeave(guardContext)),
            ),
            const SizedBox(width: 6),
            IgnorePointer(
              ignoring: !canUndo,
              child: Opacity(
                opacity: canUndo ? 1 : .42,
                child: V3LiquidGlassIconAction(
                  key: const ValueKey<String>('canvas-top-undo'),
                  tooltip: '撤销',
                  semanticLabel: '撤销',
                  onTap: canUndo ? _undo : () {},
                  icon: const Icon(Icons.undo_rounded),
                ),
              ),
            ),
            const SizedBox(width: 2),
            IgnorePointer(
              ignoring: !canRedo,
              child: Opacity(
                opacity: canRedo ? 1 : .42,
                child: V3LiquidGlassIconAction(
                  key: const ValueKey<String>('canvas-top-redo'),
                  tooltip: '重做',
                  semanticLabel: '重做',
                  onTap: canRedo ? _redo : () {},
                  icon: const Icon(Icons.redo_rounded),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: V3CanvasSaveStatusLabel(indicator: policy.saveIndicator),
              ),
            ),
            if (_bootstrapPhase == _CanvasBootstrapPhase.ready)
              V3LiquidGlassIconAction(
                key: const ValueKey<String>('canvas-more-actions'),
                tooltip: '更多操作',
                semanticLabel: '更多操作',
                onTap:
                    (!policy.canUseEditorCommands && !_canStopCanvasVoice) ||
                        _linkEditorVisible
                    ? _showInteractionLocked
                    : _showCanvasMoreActions,
                icon: const Icon(Icons.more_horiz_rounded),
              )
            else
              const SizedBox.square(dimension: 44),
            const SizedBox(width: 2),
            TextButton(
              key: const ValueKey<String>('canvas-save'),
              onPressed: policy.canSave ? _confirmAndSave : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 44),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: Text(
                _saving
                    ? '保存中'
                    : policy.canContinuePendingSave || _savedDraftCleanupPending
                    ? '继续'
                    : '保存',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInitialDraftSurface() {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final state = _scriptDraftController.state;
    final failed = _bootstrapPhase == _CanvasBootstrapPhase.failed;
    final actionsLocked = _leaveHardBlocked;
    final awaitingChoice =
        _bootstrapPhase == _CanvasBootstrapPhase.awaitingDraftChoice;
    final partial = state.partialMarkdown.trim();
    return ColoredBox(
      color: tokens.canvas,
      child: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
          children: [
            Icon(
              failed ? Icons.error_outline_rounded : Icons.auto_awesome_rounded,
              size: 34,
              color: failed ? tokens.danger : tokens.accent,
            ),
            const SizedBox(height: 16),
            Text(
              failed
                  ? _unreadableSessionMetadata
                        ? '草稿状态无法安全恢复'
                        : _entryLoadFailed
                        ? '创作内容加载失败'
                        : '初稿生成失败'
                  : awaitingChoice
                  ? '请选择要打开的创作'
                  : '正在生成可编辑逐字稿',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              failed
                  ? _bootstrapErrorMessage ?? '暂时无法生成，正文尚未创建。'
                  : awaitingChoice
                  ? '当前草稿会保持原样，直到你完成选择。'
                  : _initialDraftProgressLabel(state.phase),
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.muted, height: 1.45),
            ),
            if (!failed && !awaitingChoice) ...[
              const SizedBox(height: 18),
              const Center(child: CircularProgressIndicator.adaptive()),
              if (state.phase == ScriptDraftGenerationPhase.streaming &&
                  _scriptDraftReceipt?.agentRunId != null) ...[
                const SizedBox(height: 18),
                V3LongRunningTaskNotice(
                  onReturn: _leaveInitialDraftInBackground,
                ),
              ],
            ],
            if (!failed && partial.isNotEmpty) ...[
              const SizedBox(height: 24),
              Container(
                key: const ValueKey<String>('canvas-initial-draft-preview'),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tokens.line),
                ),
                child: V3AssistantReplyMarkdown(source: partial),
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 24),
              if (_unreadableSessionMetadata)
                FilledButton.icon(
                  key: const ValueKey<String>(
                    'canvas-unreadable-session-discard',
                  ),
                  onPressed: actionsLocked
                      ? null
                      : _discardUnreadableSessionDraft,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('放弃草稿并打开当前入口'),
                )
              else
                FilledButton.icon(
                  key: const ValueKey<String>('canvas-initial-draft-retry'),
                  onPressed: actionsLocked ? null : _retryInitialDraft,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey<String>('canvas-initial-draft-return'),
                onPressed: actionsLocked ? null : _returnFromInitialDraft,
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('返回'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopicContext() {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final sourceLabel =
        _scriptDraftReceipt?.source.kind == ScriptDraftSourceKind.asset
        ? '资产来源'
        : '今日热点';
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: '$sourceLabel · ${_sourceTitle!}',
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: tokens.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.local_fire_department_outlined,
                  size: 17,
                  color: tokens.accent,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _sourceTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HuahuoV3Theme.meta.copyWith(
                      color: tokens.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCanvasMoreActions() async {
    if (_moreActionsSheetOpen) return;
    if (!await _settleCanvasVoiceBeforeSnapshot() || !mounted) return;
    if (_interactionLocked || _linkEditorVisible) {
      _showInteractionLocked();
      return;
    }
    _moreActionsSheetOpen = true;
    _CanvasMoreAction? action;
    try {
      action = await showV3ActionSheet<_CanvasMoreAction>(
        context: context,
        title: '自由创作',
        items: const [
          V3ActionSheetItem(
            value: _CanvasMoreAction.history,
            icon: Icons.history_rounded,
            label: '创作历史',
          ),
          V3ActionSheetItem(
            value: _CanvasMoreAction.newDraft,
            icon: Icons.note_add_outlined,
            label: '新建笔记',
          ),
        ],
      );
    } finally {
      _moreActionsSheetOpen = false;
    }
    if (!mounted || action == null) return;
    switch (action) {
      case _CanvasMoreAction.history:
        await _openCreationHistory();
        return;
      case _CanvasMoreAction.newDraft:
        await _startNewDraft();
        return;
    }
  }

  void _endCanvasVoiceBeforeNavigation() {
    if (!_ownsVoiceCapture) return;
    _ownsVoiceCapture = false;
    if (mounted) setState(() {});
    unawaited(_voiceController.endCaptureForLeave(owner: _voiceSessionOwner));
  }

  Future<void> _openCreationHistory() async {
    if (_interactionLocked) {
      _showInteractionLocked();
      return;
    }
    if (_requiresLeaveSettlement && !await _confirmDiscardForLeave(context)) {
      return;
    }
    if (!mounted) return;
    if (!_leaveSettlementInProgress) {
      _endCanvasVoiceBeforeNavigation();
    }
    if (!mounted) return;
    context.replace('/v3/workbench/history');
  }

  Widget _buildMarkdownToolbar(bool interactionLocked) => AnimatedSize(
    duration: V3MotionTokens.standard,
    curve: Curves.easeOutCubic,
    alignment: Alignment.bottomCenter,
    child: DecoratedBox(
      key: const ValueKey<String>('canvas-markdown-toolbar'),
      decoration: BoxDecoration(
        color: HuahuoV3Theme.tokensOf(context).canvas,
        border: Border(
          top: BorderSide(color: HuahuoV3Theme.tokensOf(context).line),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_toolbarHasSecondaryRow) ...[
            IgnorePointer(
              ignoring: !_bodyCommandsAvailable,
              child: SizedBox(height: 54, child: _buildToolbarSecondaryRow()),
            ),
            Divider(height: 1, color: HuahuoV3Theme.tokensOf(context).line),
          ],
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: V3CanvasEditingModeSwitch(
                    value: _editingMode,
                    onChanged: _interactionPolicy.canSwitchEditingMode
                        ? _changeEditingMode
                        : null,
                    onBlocked: () {
                      _recordCanvasState(
                        'editing_mode_blocked',
                        metadata: {'reason': _interactionLockedMessage},
                      );
                      _showInteractionLocked();
                    },
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: VerticalDivider(
                    width: 1,
                    color: HuahuoV3Theme.tokensOf(context).line,
                  ),
                ),
                Expanded(
                  child: _editingMode == CanvasEditingMode.ai
                      ? _buildAiActionRow()
                      : _buildManualToolbarRow(),
                ),
                SizedBox(
                  height: 28,
                  child: VerticalDivider(
                    width: 1,
                    color: HuahuoV3Theme.tokensOf(context).line,
                  ),
                ),
                _CanvasToolButton(
                  key: const ValueKey<String>('canvas-keyboard-toggle'),
                  tooltip: MediaQuery.viewInsetsOf(context).bottom > 0
                      ? '收起键盘'
                      : '唤出键盘',
                  icon: MediaQuery.viewInsetsOf(context).bottom > 0
                      ? Icons.keyboard_hide_rounded
                      : Icons.keyboard_alt_outlined,
                  onPressed: interactionLocked ? null : _toggleKeyboard,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildManualToolbarRow() => SingleChildScrollView(
    key: const ValueKey<String>('canvas-primary-toolbar-scroll'),
    scrollDirection: Axis.horizontal,
    physics: const BouncingScrollPhysics(),
    child: Row(
      children: [
        _CanvasToolButton(
          tooltip: '加粗',
          icon: Icons.format_bold_rounded,
          selected: _hasSelectionAttribute(Attribute.bold.key),
          onPressed: _bodyCommand(() => _toggleAttribute(Attribute.bold)),
        ),
        _CanvasToolButton(
          tooltip: '斜体',
          icon: Icons.format_italic_rounded,
          selected: _hasSelectionAttribute(Attribute.italic.key),
          onPressed: _bodyCommand(() => _toggleAttribute(Attribute.italic)),
        ),
        _CanvasToolButton(
          key: const ValueKey<String>('canvas-text-style'),
          tooltip: '更多文字格式',
          label: 'Aa',
          selected: _toolbarPanel == _CanvasToolbarPanel.text,
          onPressed: _bodyCommandsAvailable
              ? () => _toggleToolbarPanel(_CanvasToolbarPanel.text)
              : null,
        ),
        _CanvasToolButton(
          key: const ValueKey<String>('canvas-block-style'),
          tooltip: '段落样式',
          label: 'T',
          selected: _toolbarPanel == _CanvasToolbarPanel.block,
          onPressed: _bodyCommandsAvailable
              ? () => _toggleToolbarPanel(_CanvasToolbarPanel.block)
              : null,
        ),
        _CanvasToolButton(
          key: const ValueKey<String>('canvas-alignment'),
          tooltip: '段落对齐',
          icon: _currentAlignmentIcon(),
          selected: _toolbarPanel == _CanvasToolbarPanel.alignment,
          onPressed: _bodyCommandsAvailable
              ? () => _toggleToolbarPanel(_CanvasToolbarPanel.alignment)
              : null,
        ),
        _CanvasToolButton(
          key: const ValueKey<String>('canvas-import-notes'),
          tooltip: '导入笔记',
          icon: Icons.note_add_outlined,
          onPressed: _bodyCommandAsync(_openKnowledgeNotePicker),
        ),
        _CanvasToolButton(
          key: const ValueKey<String>('canvas-voice-dictation'),
          tooltip: _voiceControlEngaged ? '完成语音转写' : '语音转写',
          onPressed: _voiceState.isBusy
              ? null
              : _voiceControlEngaged
              ? (_canStopCanvasVoice ? _toggleCanvasVoice : null)
              : _bodyCommandsAvailable
              ? _toggleCanvasVoice
              : null,
          icon: _voiceControlEngaged
              ? Icons.mic_rounded
              : Icons.mic_none_rounded,
          selected: _voiceControlEngaged,
        ),
      ],
    ),
  );

  Widget _buildAiActionRow() {
    final selection = _normalizedBodySelection(useFrozen: true);
    final hasSelection = !selection.isCollapsed;
    final compact = MediaQuery.sizeOf(context).width < 360;
    return KeyedSubtree(
      key: const ValueKey<String>('canvas-ai-action-row'),
      child: SingleChildScrollView(
        key: const ValueKey<String>('canvas-ai-action-list'),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            SizedBox(
              width: compact ? 136 : 184,
              child: SegmentedButton<CanvasAiEditScope>(
                key: const ValueKey<String>('canvas-ai-scope-selector'),
                showSelectedIcon: false,
                segments: <ButtonSegment<CanvasAiEditScope>>[
                  ButtonSegment<CanvasAiEditScope>(
                    value: CanvasAiEditScope.global,
                    icon: compact
                        ? null
                        : const Icon(Icons.article_outlined, size: 17),
                    label: const Text('全文'),
                  ),
                  ButtonSegment<CanvasAiEditScope>(
                    value: CanvasAiEditScope.local,
                    icon: compact
                        ? null
                        : const Icon(Icons.select_all_rounded, size: 17),
                    label: Text(compact ? '选区' : '选中文字'),
                    enabled: hasSelection,
                  ),
                ],
                selected: <CanvasAiEditScope>{_aiEditScope},
                onSelectionChanged: !_bodyCommandsAvailable
                    ? null
                    : (selection) {
                        if (selection.isEmpty) return;
                        final next = selection.first;
                        if (next == CanvasAiEditScope.local && !hasSelection) {
                          return;
                        }
                        _freezeBodySelection();
                        setState(() => _aiEditScope = next);
                      },
              ),
            ),
            const SizedBox(width: 6),
            for (final action in CanvasAiAction.values)
              _CanvasAiActionButton(
                key: ValueKey<String>('canvas-ai-action-${action.name}'),
                action: action,
                onPressed:
                    _bodyCommandsAvailable && _interactionPolicy.canStartAi
                    ? () => unawaited(_runAiActionFromToolbar(action))
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarSecondaryRow() {
    return switch (_toolbarPanel) {
      _CanvasToolbarPanel.ai => const SizedBox.shrink(),
      _CanvasToolbarPanel.text => _buildTextStyleRow(),
      _CanvasToolbarPanel.block => _buildBlockStyleRow(),
      _CanvasToolbarPanel.alignment => _buildAlignmentRow(),
      _CanvasToolbarPanel.none => const SizedBox.shrink(),
    };
  }

  void _changeEditingMode(CanvasEditingMode mode) {
    _recordCanvasState(
      'editing_mode_requested',
      metadata: {
        'mode': mode.name,
        'allowed': _interactionPolicy.canSwitchEditingMode,
      },
    );
    if (!_interactionPolicy.canSwitchEditingMode) {
      _showInteractionLocked();
      return;
    }
    _titleFocus.unfocus();
    _activeEditorTarget = _CanvasEditorTarget.body;
    if (mode == _editingMode) {
      _bodyFocus.requestFocus();
      return;
    }
    if (mode == CanvasEditingMode.ai) {
      if (_bodyIsEmpty) {
        _showCanvasSnack('先写下一些内容，再使用 AI 创作工具');
        _bodyFocus.requestFocus();
        return;
      }
      _freezeBodySelection();
      final hasSelection = !_normalizedBodySelection(
        useFrozen: true,
      ).isCollapsed;
      setState(() {
        _aiEditScope = hasSelection
            ? CanvasAiEditScope.local
            : CanvasAiEditScope.global;
        _toolbarPanel = _CanvasToolbarPanel.ai;
      });
      _bodyFocus.requestFocus();
      return;
    }
    _restoreFrozenBodySelection();
    _frozenBodySelection = null;
    setState(() => _toolbarPanel = _CanvasToolbarPanel.none);
    _bodyFocus.requestFocus();
  }

  Future<void> _runAiActionFromToolbar(CanvasAiAction action) async {
    if (!_bodyCommandsAvailable ||
        !_interactionPolicy.canStartAi ||
        _bodyIsEmpty) {
      return;
    }
    _freezeBodySelection();
    final hasSelection = !_normalizedBodySelection(useFrozen: true).isCollapsed;
    final scope = _aiEditScope == CanvasAiEditScope.local && hasSelection
        ? CanvasAiEditScope.local
        : CanvasAiEditScope.global;
    if (scope != _aiEditScope && mounted) {
      setState(() => _aiEditScope = scope);
    }
    await _prepareAndRunAction(action, editScope: scope);
  }

  Widget _buildTextStyleRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    physics: const BouncingScrollPhysics(),
    child: Row(
      children: [
        _CanvasToolButton(
          tooltip: '下划线',
          icon: Icons.format_underline_rounded,
          selected: _hasSelectionAttribute(Attribute.underline.key),
          onPressed: _bodyCommand(() => _toggleAttribute(Attribute.underline)),
        ),
        _CanvasToolButton(
          tooltip: '删除线',
          icon: Icons.strikethrough_s_rounded,
          selected: _hasSelectionAttribute(Attribute.strikeThrough.key),
          onPressed: _bodyCommand(
            () => _toggleAttribute(Attribute.strikeThrough),
          ),
        ),
        _CanvasToolButton(
          tooltip: '行内代码',
          icon: Icons.code_rounded,
          selected: _hasSelectionAttribute(Attribute.inlineCode.key),
          onPressed: _bodyCommand(() => _toggleAttribute(Attribute.inlineCode)),
        ),
        _CanvasToolButton(
          tooltip: '链接',
          icon: Icons.link_rounded,
          onPressed:
              _bodyCommandsAvailable && _interactionPolicy.canStartLinkEditing
              ? () => unawaited(_insertLink())
              : null,
        ),
      ],
    ),
  );

  Widget _buildBlockStyleRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    physics: const BouncingScrollPhysics(),
    child: Row(
      children: [
        _CanvasToolButton(
          tooltip: '正文',
          label: 'T',
          selected: _selectionIsParagraph,
          onPressed: _bodyCommand(
            () => _setHeadingLevel(_CanvasHeadingLevel.paragraph),
          ),
        ),
        _CanvasToolButton(
          tooltip: '一级标题',
          label: 'H1',
          selected:
              _body
                  .getSelectionStyle()
                  .attributes[Attribute.header.key]
                  ?.value ==
              Attribute.h1.value,
          onPressed: _bodyCommand(
            () => _setHeadingLevel(_CanvasHeadingLevel.h1),
          ),
        ),
        _CanvasToolButton(
          tooltip: '二级标题',
          label: 'H2',
          selected:
              _body
                  .getSelectionStyle()
                  .attributes[Attribute.header.key]
                  ?.value ==
              Attribute.h2.value,
          onPressed: _bodyCommand(
            () => _setHeadingLevel(_CanvasHeadingLevel.h2),
          ),
        ),
        _CanvasToolButton(
          tooltip: '三级标题',
          label: 'H3',
          selected:
              _body
                  .getSelectionStyle()
                  .attributes[Attribute.header.key]
                  ?.value ==
              Attribute.h3.value,
          onPressed: _bodyCommand(
            () => _setHeadingLevel(_CanvasHeadingLevel.h3),
          ),
        ),
        _CanvasToolButton(
          tooltip: '任务列表',
          icon: Icons.checklist_rounded,
          selected: _selectionIsTaskList,
          onPressed: _bodyCommand(
            () => _toggleBlockAttribute(Attribute.unchecked),
          ),
        ),
        _CanvasToolButton(
          tooltip: '有序列表',
          icon: Icons.format_list_numbered_rounded,
          selected: _selectionHasAttributeValue(Attribute.ol),
          onPressed: _bodyCommand(() => _toggleBlockAttribute(Attribute.ol)),
        ),
        _CanvasToolButton(
          tooltip: '无序列表',
          icon: Icons.format_list_bulleted_rounded,
          selected: _selectionHasAttributeValue(Attribute.ul),
          onPressed: _bodyCommand(() => _toggleBlockAttribute(Attribute.ul)),
        ),
        _CanvasToolButton(
          tooltip: '代码块',
          icon: Icons.data_object_rounded,
          selected: _hasSelectionAttribute(Attribute.codeBlock.key),
          onPressed: _bodyCommand(
            () => _toggleBlockAttribute(Attribute.codeBlock),
          ),
        ),
        _CanvasToolButton(
          tooltip: '引用',
          icon: Icons.format_quote_rounded,
          selected: _hasSelectionAttribute(Attribute.blockQuote.key),
          onPressed: _bodyCommand(
            () => _toggleBlockAttribute(Attribute.blockQuote),
          ),
        ),
        _CanvasToolButton(
          tooltip: '分隔线',
          icon: Icons.horizontal_rule_rounded,
          onPressed: _bodyCommand(_insertDivider),
        ),
      ],
    ),
  );

  Widget _buildAlignmentRow() => Row(
    children: [
      _CanvasToolButton(
        tooltip: '左对齐',
        icon: Icons.format_align_left_rounded,
        selected: _selectionAlignment == _CanvasTextAlignment.left,
        onPressed: _bodyCommand(() => _setAlignment(_CanvasTextAlignment.left)),
      ),
      _CanvasToolButton(
        tooltip: '居中对齐',
        icon: Icons.format_align_center_rounded,
        selected: _selectionAlignment == _CanvasTextAlignment.center,
        onPressed: _bodyCommand(
          () => _setAlignment(_CanvasTextAlignment.center),
        ),
      ),
      _CanvasToolButton(
        tooltip: '右对齐',
        icon: Icons.format_align_right_rounded,
        selected: _selectionAlignment == _CanvasTextAlignment.right,
        onPressed: _bodyCommand(
          () => _setAlignment(_CanvasTextAlignment.right),
        ),
      ),
    ],
  );

  Widget _buildInlineLinkEditor(
    bool interactionLocked, {
    required double maxHeight,
  }) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final compact = MediaQuery.sizeOf(context).width < 360;
    return SizedBox(
      height: math.min(compact ? 300 : 280, maxHeight),
      child: DecoratedBox(
        key: ValueKey<String>(
          _linkEditingExisting
              ? 'canvas-link-editor-existing'
              : 'canvas-link-editor-new',
        ),
        decoration: BoxDecoration(
          color: tokens.canvas,
          border: Border(top: BorderSide(color: tokens.line)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: SingleChildScrollView(
            key: const ValueKey<String>('canvas-link-fields-scroll'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _linkEditingExisting ? '编辑链接' : '添加链接',
                  style: HuahuoV3Theme.listTitle.copyWith(color: tokens.ink),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey<String>('canvas-markdown-link-label'),
                  controller: _linkLabel,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  enabled: !interactionLocked,
                  maxLength: 512,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '显示文字',
                    hintText: '不填写时显示链接地址',
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: tokens.surfaceMuted,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tokens.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tokens.line),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey<String>('canvas-markdown-link-input'),
                  controller: _linkUrl,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  enabled: !interactionLocked,
                  autofocus: true,
                  maxLength: 2048,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _applyLink(),
                  decoration: InputDecoration(
                    labelText: '链接地址',
                    hintText: 'https://example.com',
                    errorText: _linkError,
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: tokens.surfaceMuted,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tokens.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tokens.line),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    runAlignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_linkEditingExisting)
                        OutlinedButton.icon(
                          key: const ValueKey<String>('canvas-link-remove'),
                          onPressed: interactionLocked ? null : _removeLink,
                          icon: const Icon(Icons.link_off_rounded, size: 18),
                          label: const Text('移除链接'),
                        ),
                      TextButton(
                        key: const ValueKey<String>('canvas-link-cancel'),
                        onPressed: interactionLocked ? null : _closeLinkEditor,
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        key: ValueKey<String>(
                          _linkEditingExisting
                              ? 'canvas-link-done'
                              : 'canvas-link-apply',
                        ),
                        onPressed: interactionLocked ? null : _applyLink,
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.ink,
                          foregroundColor: tokens.canvas,
                          minimumSize: const Size(80, 44),
                        ),
                        child: const Text('应用链接'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCanvasVoice() async {
    if (!_routeVisible || _saving || _leaveSettlementInProgress) return;
    if (_interactionLocked && !_ownsVoiceCapture) {
      _showInteractionLocked();
      return;
    }
    final state = _voiceController.state;
    if (state.isBusy) return;
    if (state.isCaptureActive) {
      if (!_ownsVoiceCapture ||
          !state.belongsToLiveTranscript(_voiceSessionOwner)) {
        _voiceFailureDialogGate.beginAttempt();
        await _presentCanvasVoiceFailure(
          'CHAT_LIVE_TRANSCRIPT_SESSION_BUSY',
          attemptId: state.liveTranscriptAttemptId,
        );
        return;
      }
      final stopped = await _voiceController.stopAndTranscribe(
        owner: _voiceSessionOwner,
      );
      if (!mounted ||
          !_routeVisible ||
          !_ownsVoiceCapture ||
          _leaveSettlementInProgress) {
        return;
      }
      if (!stopped) {
        if (_voiceController.state.lastErrorCode == null) {
          await _presentCanvasVoiceFailure(
            'VOICE_TRANSCRIPTION_FAILED',
            attemptId: _voiceController.state.liveTranscriptAttemptId,
          );
        }
        return;
      }
      final transcript = _voiceController.state.liveTranscriptText.trim();
      _applyCanvasVoiceTranscript(_voiceController.state);
      setState(() {
        _ownsVoiceCapture = false;
        _voiceNoSpeech = transcript.isEmpty;
      });
      _showCanvasSnack(
        transcript.isEmpty ? '没有听清，点麦克风重试' : '语音已转为文字',
        duration: V3FeedbackTimingTokens.brief,
      );
      return;
    }

    _bodyFocus.requestFocus();
    final selection = _normalizedBodySelection();
    _voiceInsertionOffset = selection.start;
    _voiceReplacementLength = selection.end - selection.start;
    _voiceInsertedLength = 0;
    _lastVoiceTranscript = '';
    _voiceFailureDialogGate.beginAttempt();
    setState(() {
      _ownsVoiceCapture = true;
      _voiceNoSpeech = false;
    });
    final started = await _voiceController.startLiveTranscription(
      owner: _voiceSessionOwner,
    );
    if (!mounted ||
        started ||
        !_routeVisible ||
        !_ownsVoiceCapture ||
        _leaveSettlementInProgress) {
      return;
    }
    final errorCode = _voiceController.state.lastErrorCode;
    if (errorCode == null) {
      setState(() => _ownsVoiceCapture = false);
      await _presentCanvasVoiceFailure(
        'VOICE_TRANSCRIPTION_FAILED',
        attemptId: _voiceController.state.liveTranscriptAttemptId,
      );
    }
  }

  void _handleCanvasVoiceStateChanged() {
    if (!mounted ||
        !_routeVisible ||
        !_ownsVoiceCapture ||
        _saving ||
        _leaveSettlementInProgress) {
      return;
    }
    if (_isInitialDraftBusy ||
        _isAiBusy(_canvasAiController.status) ||
        _historyCommitReceipt != null ||
        _unreadableSessionMetadata) {
      return;
    }
    final state = _voiceController.state;
    if (!state.belongsToLiveTranscript(_voiceSessionOwner)) return;
    _applyCanvasVoiceTranscript(state);
    final errorCode = state.lastErrorCode;
    if (errorCode != null) {
      _ownsVoiceCapture = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _routeVisible) {
          unawaited(
            _presentCanvasVoiceFailure(
              errorCode,
              attemptId: state.liveTranscriptAttemptId,
            ),
          );
        }
      });
    }
    setState(() {});
  }

  Future<void> _presentCanvasVoiceFailure(
    String errorCode, {
    int? attemptId,
  }) async {
    if (!mounted ||
        !_routeVisible ||
        !_voiceFailureDialogGate.claim(
          owner: _voiceSessionOwner,
          attemptId: attemptId,
        )) {
      return;
    }
    late final LiveTranscriptionFailureDialogAction action;
    try {
      action = await showLiveTranscriptionFailureDialog(
        context: context,
        errorCode: errorCode,
        wasTranscribing: _lastVoiceTranscript.isNotEmpty,
      );
    } finally {
      _voiceFailureDialogGate.release();
    }
    if (!mounted || !_routeVisible || _leaveSettlementInProgress) return;
    switch (action) {
      case LiveTranscriptionFailureDialogAction.openSettings:
        await _openCanvasVoicePermissionSettings();
        break;
      case LiveTranscriptionFailureDialogAction.retry:
        await _toggleCanvasVoice();
        break;
      case LiveTranscriptionFailureDialogAction.dismiss:
        break;
    }
  }

  void _applyCanvasVoiceTranscript(VoiceMessageState state) {
    if (!mounted ||
        !_routeVisible ||
        !_ownsVoiceCapture ||
        _saving ||
        _leaveSettlementInProgress ||
        _isInitialDraftBusy ||
        _isAiBusy(_canvasAiController.status) ||
        _historyCommitReceipt != null ||
        _unreadableSessionMetadata ||
        !state.isLiveTranscription ||
        !state.belongsToLiveTranscript(_voiceSessionOwner)) {
      return;
    }
    final offset = _voiceInsertionOffset;
    final transcript = state.liveTranscriptText.trim();
    if (offset == null ||
        transcript.isEmpty ||
        transcript == _lastVoiceTranscript) {
      return;
    }
    final safeOffset = offset
        .clamp(0, math.max(0, _body.document.length - 1))
        .toInt();
    final firstTranscript = _lastVoiceTranscript.isEmpty;
    final requestedLength = firstTranscript
        ? _voiceReplacementLength
        : _voiceInsertedLength;
    final safeLength = requestedLength
        .clamp(0, math.max(0, _body.document.length - 1 - safeOffset))
        .toInt();
    void replaceTranscript() {
      _body.replaceText(
        safeOffset,
        safeLength,
        transcript,
        TextSelection.collapsed(offset: safeOffset + transcript.length),
      );
    }

    if (firstTranscript) {
      _runSeparateEdit(replaceTranscript);
    } else {
      final history = _body.document.history;
      history.lastRecorded = DateTime.now().millisecondsSinceEpoch;
      try {
        replaceTranscript();
      } finally {
        history.lastRecorded = 0;
      }
    }
    _voiceInsertedLength = transcript.length;
    _lastVoiceTranscript = transcript;
    _autosaveCoordinator.schedule();
  }

  Future<bool> _settleCanvasVoiceBeforeSnapshot() async {
    if (!_ownsVoiceCapture) return true;
    if (_voiceState.isBusy) {
      _showCanvasSnack('语音输入正在处理中，请稍候');
      return false;
    }
    await _toggleCanvasVoice();
    if (!mounted) return false;
    if (_ownsVoiceCapture) {
      _showCanvasSnack('请先结束语音输入，再继续');
      return false;
    }
    _synchronizeDocumentState(scheduleAutosave: false);
    return true;
  }

  Future<void> _openCanvasVoicePermissionSettings() async {
    await ref
        .read(platformPermissionsPortProvider)
        .openAppSettings(
          PlatformPermissionKind.microphone,
          impactAcknowledged: true,
        );
  }

  void _toggleToolbarPanel(_CanvasToolbarPanel panel) {
    if (!_ensureBodyEditor()) return;
    final next = _toolbarPanel == panel ? _CanvasToolbarPanel.none : panel;
    if (next == _CanvasToolbarPanel.none) {
      _frozenBodySelection = null;
    } else {
      _freezeBodySelection();
    }
    setState(() {
      _toolbarPanel = next;
    });
  }

  Widget _buildBodyContextMenu(
    BuildContext context,
    QuillRawEditorState editorState,
  ) {
    final nativeActions = editorState.contextMenuButtonItems;
    final review = _inlineAiReview;
    if (review != null) {
      final candidateCopyText = review.editor.selection.isCollapsed
          ? ''
          : review.candidateTextForProjectionSelection(review.editor.selection);
      final reviewItems = <ContextMenuButtonItem>[
        if (candidateCopyText.isNotEmpty)
          ContextMenuButtonItem(
            label: '复制接受后文本',
            onPressed: () {
              _copyInlineAiReviewSelection();
              ContextMenuController.removeAny();
            },
          ),
        ...nativeActions.where(
          (item) => item.type == ContextMenuButtonType.selectAll,
        ),
      ];
      return TextFieldTapRegion(
        child: AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editorState.contextMenuAnchors,
          buttonItems: V3TextEditing.localizeButtonItems(context, reviewItems),
        ),
      );
    }
    final selection = _normalizedBodySelection();
    final buttonItems = <ContextMenuButtonItem>[
      ...V3TextEditing.localizeButtonItems(context, nativeActions),
      if (!selection.isCollapsed)
        ContextMenuButtonItem(label: 'AI 改写', onPressed: _openSelectedAiTools),
    ];
    return TextFieldTapRegion(
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editorState.contextMenuAnchors,
        buttonItems: buttonItems,
      ),
    );
  }

  bool _copyInlineAiReviewSelection() {
    final review = _inlineAiReview;
    if (review == null) return false;
    final text = review.candidateTextForProjectionSelection(
      review.editor.selection,
    );
    if (text.isEmpty) {
      _showCanvasSnack('所选内容接受后为空', duration: V3FeedbackTimingTokens.brief);
      return false;
    }
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _showCanvasSnack(
      V3TextEditing.copySucceededMessage,
      duration: V3FeedbackTimingTokens.brief,
    );
    return true;
  }

  KeyEventResult? _handleReviewKeyPressed(KeyEvent event, Node? _) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        (!HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isControlPressed)) {
      return null;
    }
    final key = event.logicalKey;
    final shifted = HardwareKeyboard.instance.isShiftPressed;
    if ((key == LogicalKeyboardKey.keyC ||
            key == LogicalKeyboardKey.keyL ||
            key == LogicalKeyboardKey.keyO ||
            key == LogicalKeyboardKey.keyS) &&
        !shifted) {
      return null;
    }
    final mutationKeys = <LogicalKeyboardKey>{
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyY,
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyU,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.backquote,
      LogicalKeyboardKey.tilde,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    };
    return mutationKeys.contains(key) ? KeyEventResult.handled : null;
  }

  InlineSpan _buildReviewTextSpan(
    BuildContext context,
    Node node,
    int nodeOffset,
    String text,
    TextStyle? style,
    GestureRecognizer? recognizer,
  ) {
    final change = CanvasAiInlineReview.changeFor(node.style.toJson());
    final spokenText = text.replaceAll('\n', ' ').trim();
    final changeLabel = switch (change) {
      CanvasReviewChange.deleted => '删除',
      CanvasReviewChange.inserted => '新增',
      null => null,
    };
    return TextSpan(
      text: text,
      style: style,
      recognizer: recognizer,
      mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
      semanticsLabel: changeLabel == null || spokenText.isEmpty
          ? null
          : '$changeLabel：$spokenText',
    );
  }

  void _openSelectedAiTools() {
    if (_body.selection.isCollapsed) return;
    _frozenBodySelection = _body.selection;
    ContextMenuController.removeAny();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreFrozenBodySelection();
      unawaited(_showAiTools());
    });
  }

  CanvasEntryIntent _normalizedEntryIntent(CanvasEntryIntent intent) =>
      intent.isValid ? intent : const CanvasEntryIntent.blank();

  String _entryIntentTransitionIdentity(CanvasEntryIntent intent) {
    final normalized = _normalizedEntryIntent(intent);
    return _canvasEntryIdentity(normalized, _scriptDraftSourceFor(normalized));
  }

  void _queueEntryIntent(
    CanvasEntryIntent intent, {
    bool recoverRoute = false,
  }) {
    final normalized = _normalizedEntryIntent(intent);
    if (!recoverRoute &&
        _entryIntentTransitionIdentity(normalized) == _entryIdentity &&
        _pendingEntryIntent == null) {
      return;
    }
    _pendingEntryIntent = (
      intent: normalized,
      recoverySessionId: recoverRoute ? widget.recoverySessionId : null,
      recoveryRunId: recoverRoute ? widget.recoveryRunId : null,
    );
    _entryIntentTransitionFailed = false;
    if (mounted) setState(() {});
    _schedulePendingEntryIntentTransition();
  }

  void _schedulePendingEntryIntentTransition() {
    if (_pendingEntryIntent == null ||
        _entryIntentTransitionScheduled ||
        _entryIntentTransitionInProgress ||
        _entryIntentTransitionFailed ||
        _historyCommitReceipt != null ||
        _savedDraftCleanupPending ||
        _linkEditorVisible ||
        _saving ||
        _leaveSettlementInProgress ||
        _isAiBusy(_canvasAiController.status) ||
        _bootstrapPhase == _CanvasBootstrapPhase.resolving ||
        _bootstrapPhase == _CanvasBootstrapPhase.awaitingDraftChoice ||
        _bootstrapPhase == _CanvasBootstrapPhase.generating) {
      return;
    }
    _entryIntentTransitionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entryIntentTransitionScheduled = false;
      if (!mounted) return;
      unawaited(_drainPendingEntryIntentTransition());
    });
  }

  void _retryPendingEntryIntentTransition() {
    if (_pendingEntryIntent == null || _entryIntentTransitionInProgress) return;
    _entryIntentTransitionFailed = false;
    setState(() {});
    _schedulePendingEntryIntentTransition();
  }

  Future<void> _drainPendingEntryIntentTransition() async {
    if (_pendingEntryIntent == null || _entryIntentTransitionInProgress) return;
    _entryIntentTransitionInProgress = true;
    _entryIntentTransitionFailed = false;
    if (mounted) setState(() {});
    try {
      if (!await _settleCanvasVoiceBeforeSnapshot() || !mounted) {
        _entryIntentTransitionFailed = true;
        return;
      }
      await _autosaveCoordinator.cancelPersistAndDrain();
      await _draftPersistence.drain();
      if (!mounted) return;
      final storedSessionId = _draftRepository.load()?.sessionId;
      if (_pendingEntryIntent?.recoverySessionId != null &&
          storedSessionId != null &&
          storedSessionId != _sessionId) {
        _entryIntentTransitionFailed = true;
        _showCanvasSnack('另一个任务的草稿已保留，请先保存当前内容，再从消息重新打开');
        return;
      }
      if (!await _persistDraftDeferred(notify: false) || !mounted) {
        _entryIntentTransitionFailed = true;
        return;
      }
      final requested = _pendingEntryIntent;
      if (requested == null) return;
      _pendingEntryIntent = null;
      _entryLoadFailed = false;
      _hydrating = true;
      _bootstrapPhase = _CanvasBootstrapPhase.resolving;
      setState(() {});
      await _restoreInitialDraft(
        requestedIntent: requested.intent,
        recoveryTarget: (
          sessionId: requested.recoverySessionId,
          runId: requested.recoveryRunId,
        ),
      );
    } finally {
      _entryIntentTransitionInProgress = false;
      if (mounted) {
        setState(() {});
        _schedulePendingEntryIntentTransition();
      }
    }
  }

  Future<void> _restoreInitialDraft({
    bool retryKnowledgeRestore = false,
    CanvasEntryIntent? requestedIntent,
    ({String? sessionId, String? runId})? recoveryTarget,
  }) async {
    final requested = _normalizedEntryIntent(
      requestedIntent ?? widget.entryIntent,
    );
    final restored = _draftRepository.load();
    final recoverySessionId = recoveryTarget != null
        ? recoveryTarget.sessionId
        : requestedIntent == null
        ? widget.recoverySessionId
        : null;
    final recoveryRunId = recoveryTarget != null
        ? recoveryTarget.runId
        : requestedIntent == null
        ? widget.recoveryRunId
        : null;
    if (recoverySessionId == null && recoveryRunId != null) {
      _failInitialDraft('生成任务入口不完整，请从消息通知重新打开', entryLoadFailure: true);
      return;
    }
    if (recoverySessionId != null) {
      if (recoverySessionId.isEmpty ||
          restored?.sessionId != recoverySessionId ||
          restored?.unreadableSessionMetadata == true ||
          restored?.scriptDraftReceipt == null ||
          (recoveryRunId != null &&
              restored?.scriptDraftReceipt?.agentRunId != recoveryRunId)) {
        _failInitialDraft(
          '这次生成的草稿已移除或替换，请从自由创作历史查看已保存的内容',
          entryLoadFailure: true,
        );
        return;
      }
      _draftRecoveryPresent = true;
      _hydrate(restored!);
      _resumeRestoredInitialDraft();
      return;
    }
    _draftRecoveryPresent = restored != null;
    final restoredBoundId = restored == null
        ? null
        : _resolveSynchronizedDraftNoteId(restored);
    if (requested is CanvasExistingNoteEntryIntent ||
        requested is CanvasHistoryEntryIntent ||
        restoredBoundId != null ||
        restored?.historyCommitReceipt != null) {
      final library = await _restoreCurrentKnowledgeLibrary(
        retryFailed: retryKnowledgeRestore,
      );
      if (!mounted) return;
      if (library == null) {
        _knowledgeRestoreFailed = true;
        _failInitialDraft('资产数据暂时无法读取，请重试', entryLoadFailure: true);
        return;
      }
      _knowledgeRestoreFailed = false;
    }
    _entryLoadFailed = false;
    _draftPersistenceSuppressed = false;
    final source = _scriptDraftSourceFor(requested);
    final incomingIdentity = _canvasEntryIdentity(requested, source);
    if (restored?.unreadableSessionMetadata == true) {
      _unreadableSessionMetadata = true;
      _entryLoadFailed = true;
      _draftPersistenceSuppressed = true;
      _hydrating = false;
      _bootstrapPhase = _CanvasBootstrapPhase.failed;
      _bootstrapErrorMessage =
          '本地草稿的会话信息不可读。为避免覆盖已有资产，原记录已保留；请返回等待升级，或明确放弃后打开当前入口。';
      if (mounted) setState(() {});
      return;
    }
    _unreadableSessionMetadata = false;
    if (!_hasRecoverableDraft(restored)) {
      _activateEntry(
        requested,
        source: source,
        entryIdentity: incomingIdentity,
      );
      return;
    }
    final restoredDraft = restored!;
    final requestedMatchesRestored = _restoredDraftMatches(
      restoredDraft,
      entryIdentity: incomingIdentity,
      source: source,
    );
    if (restoredDraft.historyCommitReceipt != null) {
      final switchesToNewAgentEntry = _isAutomaticAgentEntry(requested);
      if (switchesToNewAgentEntry) {
        _pendingEntryIntent = (
          intent: requested,
          recoverySessionId: null,
          recoveryRunId: null,
        );
      }
      await _resumePendingHistoryTransaction(restoredDraft);
      if (_isAutomaticAgentEntry(requested) &&
          mounted &&
          _bootstrapPhase == _CanvasBootstrapPhase.ready) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_confirmAndSave(requireConfirmation: false));
          }
        });
      }
      return;
    }
    final restoredMatchesEntry =
        (requested is CanvasHistoryEntryIntent ||
            requested is CanvasBlankEntryIntent) &&
        requestedMatchesRestored;
    if (_isAutomaticAgentEntry(requested)) {
      _bootstrapPhase = _CanvasBootstrapPhase.resolving;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _discardCleanRestoredDraftAndActivate(
            restoredDraft,
            requested: requested,
            source: source,
            entryIdentity: incomingIdentity,
          ),
        );
      });
      return;
    }
    final boundBaseStillCurrent = _boundDraftBaseStillCurrent(restoredDraft);

    if (boundBaseStillCurrent &&
        (restoredMatchesEntry ||
            (requested is CanvasBlankEntryIntent &&
                restoredDraft.entryIdentity == null))) {
      _hydrate(restoredDraft);
      _resumeRestoredInitialDraft();
      return;
    }

    final cleanBoundDraft =
        _resolveSynchronizedDraftNoteId(restoredDraft) != null &&
        _draftMatchesBoundAsset(restoredDraft) &&
        restoredDraft.chatRewriteReceipts.every(
          (receipt) => receipt.assistantMessageId != null,
        );
    if (cleanBoundDraft && !restoredMatchesEntry) {
      _bootstrapPhase = _CanvasBootstrapPhase.resolving;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _discardCleanRestoredDraftAndActivate(
            restoredDraft,
            requested: requested,
            source: source,
            entryIdentity: incomingIdentity,
          ),
        );
      });
      return;
    }

    _hydrate(restoredDraft);
    _bootstrapPhase = _CanvasBootstrapPhase.awaitingDraftChoice;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _resolveEntryDraftConflict(
          requested,
          source: source,
          entryIdentity: incomingIdentity,
        ),
      );
    });
  }

  Future<void> _resumePendingHistoryTransaction(
    CreationCanvasDraft restored,
  ) async {
    _hydrate(restored);
    final receipt = _historyCommitReceipt!;
    if (receipt.phase == CreationCanvasHistoryCommitPhase.prepared) {
      final library = ref.read(knowledgeLibraryControllerProvider);
      final currentTarget = library.noteForId(receipt.noteId);
      final currentFingerprint = currentTarget == null
          ? null
          : _canvasBoundAssetFingerprint(currentTarget);
      if (currentFingerprint == receipt.noteFingerprint) {
        _pendingSavedId = receipt.noteId;
        _boundAssetFingerprint = receipt.noteFingerprint;
        _historyCommitReceipt = receipt.advanceTo(
          CreationCanvasHistoryCommitPhase.noteCommitted,
        );
        _markDraftStateChanged();
        await _persistDraftDeferred(notify: false);
      } else if (receipt.baseNoteId == null) {
        if (currentTarget != null) {
          _protectPendingHistoryTransaction(
            '待保存笔记的目标位置已被其他内容占用。为避免覆盖资产，恢复记录已保留。',
          );
          return;
        }
      } else if (currentTarget == null ||
          currentFingerprint != receipt.baseNoteFingerprint) {
        _protectPendingHistoryTransaction('原资产已在保存中断后发生变化。为避免覆盖新内容，恢复记录已保留。');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _bootstrapPhase = _CanvasBootstrapPhase.ready);
  }

  void _protectPendingHistoryTransaction(String message) {
    _unreadableSessionMetadata = true;
    _entryLoadFailed = true;
    _draftPersistenceSuppressed = true;
    _hydrating = false;
    _bootstrapPhase = _CanvasBootstrapPhase.failed;
    _bootstrapErrorMessage = message;
    if (mounted) setState(() {});
  }

  Future<void> _discardCleanRestoredDraftAndActivate(
    CreationCanvasDraft restored, {
    required CanvasEntryIntent requested,
    required ScriptDraftSourceSnapshot? source,
    required String entryIdentity,
  }) async {
    if (!await _beginLeaveSettlement()) return;
    try {
      await _retireRestoredInitialGeneration(restored);
      if (!mounted) return;
      final checkpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred(notify: false);
      if (!mounted) return;
      if (!cleared) {
        _hydrate(restored);
        _showCanvasSnack('旧草稿暂时无法清理，尚未打开当前入口');
        setState(() => _bootstrapPhase = _CanvasBootstrapPhase.ready);
        return;
      }
      if (!await _validateLeaveCheckpoint(checkpoint)) return;
      _activateEntry(requested, source: source, entryIdentity: entryIdentity);
      if (mounted) setState(() {});
    } finally {
      _releaseLeaveSettlement();
    }
  }

  Future<void> _retireRestoredInitialGeneration(
    CreationCanvasDraft restored,
  ) async {
    final receipt = restored.scriptDraftReceipt;
    if (receipt == null || receipt.hasAuthoritativeResult) return;
    final agentRunId = _clean(receipt.agentRunId);
    if (agentRunId == null) return;
    try {
      await ref
          .read(scriptDraftGenerationPortProvider)
          .cancelRun(
            agentRunId: agentRunId,
            idempotencyKey: receipt.cancelIdempotencyKey,
          );
    } on Object {
      // The new Agent session has independent idempotency. A failed best-effort
      // cancellation must not turn the obsolete draft into a navigation lock.
    }
  }

  Future<void> _leaveInitialDraftInBackground() async {
    if (_leaveHardBlocked || !await _beginLeaveSettlement()) return;
    var leaving = false;
    try {
      final persisted = await _persistDraftDeferred();
      if (!mounted) return;
      if (!persisted) {
        _showCanvasSnack('生成任务暂时无法保存，请稍后重试');
        return;
      }
      setState(() => _allowLeave = true);
      leaving = true;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode));
      }
    } finally {
      if (!leaving) _releaseLeaveSettlement();
    }
  }

  bool _hasRecoverableDraft(CreationCanvasDraft? draft) =>
      draft != null &&
      (draft.title.trim().isNotEmpty ||
          draft.markdown.trim().isNotEmpty ||
          draft.documentJson?.trim().isNotEmpty == true ||
          draft.unreadableStructuredDocument ||
          draft.sourceTopicId != null ||
          draft.entryIdentity != null ||
          draft.scriptDraftReceipt != null ||
          draft.historyCommitReceipt != null ||
          draft.chatRewriteReceipts.isNotEmpty ||
          draft.linkedMaterials.isNotEmpty);

  bool _restoredDraftMatches(
    CreationCanvasDraft draft, {
    required String entryIdentity,
    required ScriptDraftSourceSnapshot? source,
  }) {
    if (draft.entryIdentity == entryIdentity) return true;
    return source != null &&
        draft.scriptDraftReceipt?.matchesSource(source) == true;
  }

  void _activateEntry(
    CanvasEntryIntent intent, {
    required ScriptDraftSourceSnapshot? source,
    required String entryIdentity,
  }) {
    _draftPersistenceSuppressed = false;
    _allowLeave = false;
    _leaveGuardIdentity = Object();
    _detachCanvasChatSession();
    _entryIdentity = entryIdentity;
    _sessionId = _newCanvasSessionId();
    _automaticInitialNoteCreation = _isAutomaticAgentEntry(intent);
    _automaticInitialNoteCreationScheduled = false;
    _scriptDraftReceipt = null;
    _boundAssetFingerprint = null;
    _pendingSavedId = null;
    _savedDraftCleanupPending = false;
    _historyCommitReceipt = null;
    _unreadableSessionMetadata = false;
    _bootstrapErrorMessage = null;
    _initialGenerationEpoch++;

    switch (intent) {
      case CanvasBlankEntryIntent():
        _resetEditor(resetAi: !_hydrating);
      case CanvasAssistantReplyEntryIntent(:final seed):
        _hydrateAssistantReplySeed(seed);
        _persistDraft();
      case CanvasExistingNoteEntryIntent(:final noteId):
        final note = ref
            .read(knowledgeLibraryControllerProvider)
            .noteForId(noteId);
        if (note == null) {
          _failInitialDraft('要打开的资产已不存在', entryLoadFailure: true);
          return;
        }
        final seed = AssetCanvasSeed.tryFromItem(
          item: note,
          stage: V3ContentStage.raw,
        );
        if (seed == null) {
          _failInitialDraft('这篇笔记没有可编辑的原始内容', entryLoadFailure: true);
          return;
        }
        final sourceIntent = CanvasEntryIntent.asset(seed);
        _resetEditor(resetAi: !_hydrating);
        _entryIdentity = entryIdentity;
        _prepareInitialDraftGeneration(
          _scriptDraftSourceFor(sourceIntent)!,
          intent: sourceIntent,
        );
      case CanvasHistoryEntryIntent(:final historyId):
        final history = _historyPort.find(_historyUserScope, historyId);
        if (history == null) {
          _failInitialDraft('这条创作历史已不存在', entryLoadFailure: true);
          return;
        }
        _hydrateHistory(history);
        _entryIdentity = entryIdentity;
      case CanvasDailyTopicEntryIntent():
        if (source == null) {
          _failInitialDraft('当前来源没有可用于生成逐字稿的有效内容');
          return;
        }
        _resetEditor(resetAi: !_hydrating);
        _entryIdentity = entryIdentity;
        _prepareInitialDraftGeneration(source, intent: intent);
      case CanvasAssetEntryIntent(:final seed):
        if (source == null) {
          _failInitialDraft('当前来源没有可用于生成逐字稿的有效内容');
          return;
        }
        final sourceMode = seed.initialSourceMode;
        _resetEditor(resetAi: !_hydrating);
        _automaticInitialNoteCreation = _isAutomaticAgentEntry(intent);
        _automaticInitialNoteCreationScheduled = false;
        _entryIdentity = entryIdentity;
        _prepareInitialDraftGeneration(
          source,
          intent: intent,
          generate: sourceMode != AssetCanvasInitialSourceMode.useOriginal,
        );
    }
  }

  void _failInitialDraft(String message, {bool entryLoadFailure = false}) {
    _hydrating = false;
    _entryLoadFailed = entryLoadFailure;
    if (entryLoadFailure) _draftPersistenceSuppressed = true;
    _bootstrapPhase = _CanvasBootstrapPhase.failed;
    _bootstrapErrorMessage = message;
    if (mounted) setState(() {});
  }

  ScriptDraftSourceSnapshot? _scriptDraftSourceFor(CanvasEntryIntent intent) {
    try {
      return switch (intent) {
        CanvasDailyTopicEntryIntent(:final seed) => ScriptDraftSourceSnapshot(
          kind: ScriptDraftSourceKind.dailyRecommendation,
          sourceId: seed.topicId,
          title: seed.title,
          content: seed.editableMarkdown,
          partRevisionId: seed.sourceRevisionId ?? seed.recommendationId,
          contentHash: seed.sourceHash,
          capturedAt: DateTime.now().toUtc(),
        ),
        CanvasAssetEntryIntent(:final seed) => ScriptDraftSourceSnapshot(
          kind: ScriptDraftSourceKind.asset,
          sourceId: seed.assetId,
          title: seed.title,
          content: seed.sourceMarkdown,
          assetPart: switch (seed.stage) {
            AssetCanvasSourceStage.raw => ScriptDraftAssetPart.raw,
            AssetCanvasSourceStage.outline => ScriptDraftAssetPart.outline,
            AssetCanvasSourceStage.sprout => ScriptDraftAssetPart.germination,
          },
          partRevisionId: seed.partRevisionId,
          contentHash: seed.sourceHash,
          capturedAt: DateTime.now().toUtc(),
        ),
        _ => null,
      };
    } on ArgumentError {
      return null;
    }
  }

  Future<void> _resolveEntryDraftConflict(
    CanvasEntryIntent requested, {
    required ScriptDraftSourceSnapshot? source,
    required String entryIdentity,
  }) async {
    final choice = await showV3ActionSheet<_DraftConflictChoice>(
      context: context,
      title: '已有未完成创作',
      message: '继续上次创作，或放弃草稿并打开当前入口。',
      items: const [
        V3ActionSheetItem(
          value: _DraftConflictChoice.continueDraft,
          icon: Icons.history_rounded,
          label: '继续上次创作',
        ),
        V3ActionSheetItem(
          value: _DraftConflictChoice.openCurrentEntry,
          icon: Icons.delete_sweep_outlined,
          label: '放弃并打开当前入口',
          destructive: true,
        ),
      ],
    );
    if (!mounted) return;
    if (choice != _DraftConflictChoice.openCurrentEntry) {
      final library = await _restoreCurrentKnowledgeLibrary();
      if (!mounted) return;
      if (library == null) {
        _knowledgeRestoreFailed = true;
        _failInitialDraft('资产数据暂时无法读取，草稿仍保留，请重试', entryLoadFailure: true);
        return;
      }
      if (!_currentBoundAssetStillMatches()) {
        _failInitialDraft(
          '原笔记已变更或删除，未完成草稿仍保留。请重新进入并选择放弃草稿、打开当前入口；不会另建笔记或覆盖新版本。',
          entryLoadFailure: true,
        );
        return;
      }
      setState(() => _bootstrapPhase = _CanvasBootstrapPhase.ready);
      _resumeRestoredInitialDraft();
      return;
    }
    if (!await _beginLeaveSettlement()) return;
    try {
      if (!await _abandonInitialDraftGenerationIfNeeded() || !mounted) return;
      if (!await _settlePendingCanvasChatForDestructiveDiscard()) {
        if (mounted) {
          setState(() => _bootstrapPhase = _CanvasBootstrapPhase.ready);
        }
        return;
      }
      if (!mounted) return;
      final checkpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred();
      if (!mounted) return;
      if (!cleared) {
        _showCanvasSnack('草稿清理失败，请稍后重试');
        setState(() => _bootstrapPhase = _CanvasBootstrapPhase.ready);
        return;
      }
      if (!await _validateLeaveCheckpoint(checkpoint)) return;
      await _deleteOwnedCanvasImages();
      if (!mounted) return;
      _activateEntry(requested, source: source, entryIdentity: entryIdentity);
      setState(() {});
    } finally {
      _releaseLeaveSettlement();
    }
  }

  void _prepareInitialDraftGeneration(
    ScriptDraftSourceSnapshot source, {
    required CanvasEntryIntent intent,
    bool generate = true,
  }) {
    _hydrating = true;
    _title.text = source.title.trim();
    _replaceBodyDocument(Document(), const TextSelection.collapsed(offset: 0));
    _body.document.history.clear();
    _ownedCanvasImageIds.clear();
    _linkedMaterialsByDocument.clear();
    _linkedMaterials
      ..clear()
      ..addAll(switch (intent) {
        CanvasAssetEntryIntent(:final seed) => <V3LinkedMaterialRef>[
          seed.linkedReference,
        ],
        CanvasDailyTopicEntryIntent(:final seed)
            when seed.linkedReference != null =>
          <V3LinkedMaterialRef>[seed.linkedReference!],
        _ => const <V3LinkedMaterialRef>[],
      });
    _sourceTopicId = source.sourceId;
    _sourceTitle = source.title.trim();
    _pendingSavedId = null;
    _boundAssetFingerprint = null;
    _documentRevision = 0;
    _draftCreatedAt = DateTime.now().toUtc();
    _lastDocumentSignature = _documentSignature;
    _finishHydration(markClean: false);
    if (!generate) {
      _adoptInitialDraft(source.content, source);
      return;
    }
    _bootstrapPhase = _CanvasBootstrapPhase.generating;
    unawaited(_driveInitialDraft(source: source));
  }

  void _resumeRestoredInitialDraft() {
    final receipt = _scriptDraftReceipt;
    if (receipt == null) {
      _bootstrapPhase = _CanvasBootstrapPhase.ready;
      return;
    }
    if (receipt.hasAuthoritativeResult) {
      if (_bodyIsEmpty) {
        _adoptInitialDraft(receipt.finalMarkdown!, receipt.source);
      } else {
        _bootstrapPhase = _CanvasBootstrapPhase.ready;
        _scheduleAutomaticInitialNoteCreation();
      }
      return;
    }
    if (!_bodyIsEmpty) {
      _bootstrapPhase = _CanvasBootstrapPhase.ready;
      _scheduleAutomaticInitialNoteCreation();
      return;
    }
    _bootstrapPhase = _CanvasBootstrapPhase.generating;
    unawaited(
      _driveInitialDraft(source: receipt.source, persistedReceipt: receipt),
    );
  }

  Future<void> _driveInitialDraft({
    required ScriptDraftSourceSnapshot source,
    ScriptDraftGenerationReceipt? persistedReceipt,
  }) async {
    if (mounted) {
      setState(() {
        _bootstrapPhase = _CanvasBootstrapPhase.generating;
        _bootstrapErrorMessage = null;
      });
    }
    final epoch = ++_initialGenerationEpoch;
    final sessionId = _sessionId;
    final succeeded = await _scriptDraftController.start(
      source: source,
      persistedReceipt: persistedReceipt,
    );
    if (!mounted ||
        epoch != _initialGenerationEpoch ||
        sessionId != _sessionId) {
      return;
    }
    final finalMarkdown = _scriptDraftController.state.finalMarkdown;
    if (succeeded && finalMarkdown?.trim().isNotEmpty == true) {
      _adoptInitialDraft(finalMarkdown!, source);
      return;
    }
    setState(() {
      _bootstrapPhase = _CanvasBootstrapPhase.failed;
      _bootstrapErrorMessage = _initialDraftFailureMessage(
        _scriptDraftController.errorCode,
      );
    });
  }

  void _adoptInitialDraft(String markdown, ScriptDraftSourceSnapshot source) {
    Document document;
    try {
      document = _documentCodec.documentFromMarkdown(markdown.trim());
    } on FormatException {
      document = Document()..insert(0, markdown.trim());
    }
    _hydrating = true;
    _title.text = source.title.trim();
    _replaceBodyDocument(
      document,
      TextSelection.collapsed(offset: math.max(0, document.length - 1)),
    );
    _body.document.history.clear();
    _documentRevision = 0;
    _lastDocumentSignature = _documentSignature;
    _finishHydration(markClean: false);
    _bootstrapPhase = _CanvasBootstrapPhase.ready;
    setState(() {});
    final sessionId = _sessionId;
    _markDraftStateChanged();
    unawaited(_persistAdoptedInitialDraft(sessionId));
  }

  Future<void> _persistAdoptedInitialDraft(String sessionId) async {
    final persisted = await _persistDraftDeferred();
    if (!mounted || sessionId != _sessionId || !persisted) return;
    _scheduleAutomaticInitialNoteCreation();
  }

  void _scheduleAutomaticInitialNoteCreation() {
    if (!_automaticInitialNoteCreation ||
        _automaticInitialNoteCreationScheduled ||
        _pendingSavedId != null ||
        _historyCommitReceipt != null ||
        _bodyIsEmpty ||
        _bootstrapPhase != _CanvasBootstrapPhase.ready) {
      return;
    }
    _automaticInitialNoteCreationScheduled = true;
    final sessionId = _sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          sessionId != _sessionId ||
          !_automaticInitialNoteCreation ||
          _pendingSavedId != null ||
          _historyCommitReceipt != null) {
        return;
      }
      unawaited(
        _confirmAndSave(
          requireConfirmation: false,
          stayOnCanvasAfterSave: true,
        ),
      );
    });
  }

  Future<void> _retryInitialDraft() async {
    if (_scriptDraftController.state.isBusy) return;
    if (_entryLoadFailed) {
      setState(() {
        _hydrating = true;
        _bootstrapPhase = _CanvasBootstrapPhase.resolving;
        _bootstrapErrorMessage = null;
      });
      await _restoreInitialDraft(
        retryKnowledgeRestore: _knowledgeRestoreFailed,
      );
      return;
    }
    if (_scriptDraftController.receipt == null) {
      final intent = widget.entryIntent;
      final source = _scriptDraftSourceFor(intent);
      if (source == null) {
        setState(() {
          _bootstrapPhase = _CanvasBootstrapPhase.failed;
          _bootstrapErrorMessage = '当前来源仍没有可用于生成逐字稿的有效内容';
        });
        return;
      }
      _entryIdentity = _canvasEntryIdentity(intent, source);
      _automaticInitialNoteCreation = _isAutomaticAgentEntry(intent);
      _automaticInitialNoteCreationScheduled = false;
      _prepareInitialDraftGeneration(source, intent: intent);
      return;
    }
    setState(() {
      _bootstrapPhase = _CanvasBootstrapPhase.generating;
      _bootstrapErrorMessage = null;
    });
    final retrySameTransport = _scriptDraftController.state.errorRetryable;
    final epoch = ++_initialGenerationEpoch;
    final sessionId = _sessionId;
    final succeeded = retrySameTransport
        ? await _scriptDraftController.retryTransport()
        : await _scriptDraftController.regenerate();
    if (!mounted ||
        epoch != _initialGenerationEpoch ||
        sessionId != _sessionId) {
      return;
    }
    final receipt = _scriptDraftController.receipt;
    final finalMarkdown = _scriptDraftController.state.finalMarkdown;
    if (succeeded &&
        receipt != null &&
        finalMarkdown?.trim().isNotEmpty == true) {
      _adoptInitialDraft(finalMarkdown!, receipt.source);
      return;
    }
    setState(() {
      _bootstrapPhase = _CanvasBootstrapPhase.failed;
      _bootstrapErrorMessage = _initialDraftFailureMessage(
        _scriptDraftController.errorCode,
      );
    });
  }

  Future<void> _discardUnreadableSessionDraft() async {
    if (!_unreadableSessionMetadata) return;
    final choice = await showV3ActionSheet<bool>(
      context: context,
      title: '放弃无法恢复的草稿？',
      message: '此操作会删除本地恢复记录，之后无法继续这份草稿。',
      items: const <V3ActionSheetItem<bool>>[
        V3ActionSheetItem<bool>(
          value: true,
          icon: Icons.delete_forever_outlined,
          label: '确认放弃并打开',
          destructive: true,
        ),
      ],
    );
    if (!mounted || choice != true) return;
    if (!await _beginLeaveSettlement()) return;
    try {
      final checkpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred();
      if (!mounted) return;
      if (!cleared) {
        _draftPersistenceSuppressed = true;
        _showCanvasSnack('草稿记录暂时无法删除，请重试');
        return;
      }
      if (!await _validateLeaveCheckpoint(checkpoint)) return;
      final requested = widget.entryIntent.isValid
          ? widget.entryIntent
          : const CanvasEntryIntent.blank();
      final source = _scriptDraftSourceFor(requested);
      _unreadableSessionMetadata = false;
      _entryLoadFailed = false;
      _activateEntry(
        requested,
        source: source,
        entryIdentity: _canvasEntryIdentity(requested, source),
      );
      if (mounted) setState(() {});
    } finally {
      _releaseLeaveSettlement();
    }
  }

  Future<void> _returnFromInitialDraft() async {
    if (!await _beginLeaveSettlement()) return;
    if (!mounted) return;
    var retainLock = false;
    try {
      if (_entryLoadFailed) {
        setState(() => _allowLeave = true);
        retainLock = true;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode));
        }
        return;
      }
      if (!await _abandonInitialDraftGenerationIfNeeded() || !mounted) return;
      final checkpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred();
      if (!mounted) return;
      if (!cleared) {
        _showCanvasSnack('生成会话暂时无法清理，请重试');
        return;
      }
      final checkpointIsCurrent = await _validateLeaveCheckpoint(checkpoint);
      if (!mounted || !checkpointIsCurrent) return;
      setState(() => _allowLeave = true);
      retainLock = true;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode));
      }
    } finally {
      if (!retainLock) _releaseLeaveSettlement();
    }
  }

  Future<void> _persistScriptDraftReceipt(
    ScriptDraftGenerationReceipt receipt,
  ) async {
    _scriptDraftReceipt = receipt;
    if (_hydrating || _allowLeave) return;
    final persisted = await _persistDraftDeferred();
    if (!persisted) {
      throw StateError('SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED');
    }
  }

  void _handleScriptDraftStateChanged() {
    if (mounted) setState(() {});
  }

  void _hydrate(CreationCanvasDraft draft) {
    _title.text = draft.title;
    _unreadableStructuredDraft =
        draft.unreadableStructuredDocument && draft.markdown.trim().isEmpty;
    Document? document;
    if (draft.documentFormatVersion ==
            CanvasDocumentCodec.documentFormatVersion &&
        draft.documentJson != null) {
      try {
        document = _documentCodec.documentFromDeltaJson(draft.documentJson!);
      } on FormatException {
        document = null;
      }
    }
    if (document == null) {
      try {
        document = _documentCodec.documentFromMarkdown(draft.markdown);
      } on FormatException {
        document = Document()..insert(0, draft.markdown);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _showCanvasSnack('草稿已按纯文本恢复');
        });
      }
    }
    _replaceBodyDocument(
      document,
      TextSelection.collapsed(offset: math.max(0, document.length - 1)),
    );
    _body.document.history.clear();
    _ownedCanvasImageIds
      ..clear()
      ..addAll(_canvasImageIdsInDocument());
    _linkedMaterials
      ..clear()
      ..addAll(draft.linkedMaterials);
    _sourceTopicId = draft.sourceTopicId;
    _sourceTitle = draft.sourceTitle;
    _pendingSavedId = _resolveSynchronizedDraftNoteId(draft);
    _boundAssetFingerprint = _clean(draft.boundAssetFingerprint);
    _sessionId = _clean(draft.sessionId) ?? _newCanvasSessionId();
    _entryIdentity = _clean(draft.entryIdentity);
    _scriptDraftReceipt = draft.scriptDraftReceipt;
    final legacyAgentDraft =
        _pendingSavedId == null &&
        _scriptDraftReceipt?.source.kind == ScriptDraftSourceKind.asset;
    if (legacyAgentDraft && !_isAutomaticAgentIdentity(_entryIdentity)) {
      _entryIdentity = 'agent-note:${_scriptDraftReceipt!.source.identity}';
    }
    final pendingAgentCreation =
        draft.historyCommitReceipt != null &&
        draft.historyCommitReceipt!.baseNoteId == null;
    final pendingAgentInitialCleanup =
        draft.savedDraftCleanupPending &&
        _pendingSavedId != null &&
        _scriptDraftReceipt?.hasAuthoritativeResult == true;
    _automaticInitialNoteCreation =
        (_isAutomaticAgentIdentity(_entryIdentity) || legacyAgentDraft) &&
        (_pendingSavedId == null ||
            pendingAgentCreation ||
            pendingAgentInitialCleanup);
    _automaticInitialNoteCreationScheduled =
        draft.historyCommitReceipt != null || pendingAgentInitialCleanup;
    _chatThreadId = _clean(draft.chatThreadId);
    _savedDraftCleanupPending = draft.savedDraftCleanupPending;
    _historyCommitReceipt = draft.historyCommitReceipt;
    final discardedStaleChatReceipt = draft.chatRewriteReceipts.any(
      (receipt) =>
          receipt.assistantMessageId == null &&
          receipt.submissionPhase !=
              CreationCanvasChatSubmissionPhase.prepared &&
          !_canvasChatControllerOwns(receipt),
    );
    _restoreChatRewriteReceipts(draft.chatRewriteReceipts);
    _unreadableSessionMetadata = false;
    _documentRevision = draft.revision;
    _draftCreatedAt = draft.createdAt;
    _lastDocumentSignature = _documentSignature;
    _rememberLinkedMaterialsForDocument();
    _finishHydration(markClean: _draftMatchesBoundAsset(draft));
    if (discardedStaleChatReceipt) {
      _persistDraft();
    }
    if (_unreadableStructuredDraft || _unreadableSessionMetadata) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCanvasSnack('结构化草稿不可读，原始记录已保留');
      });
    }
  }

  void _hydrateAssistantReplySeed(AssistantReplyCanvasSeed seed) {
    _hydrating = true;
    _autosaveCoordinator.cancelCloudSync();
    _title.text = seed.title.trim();
    final markdown = seed.markdown.trim();
    Document document;
    try {
      document = _documentCodec.documentFromMarkdown(markdown);
    } on FormatException {
      document = Document()..insert(0, markdown);
    }
    _replaceBodyDocument(document, const TextSelection.collapsed(offset: 0));
    _body.document.history.clear();
    _ownedCanvasImageIds.clear();
    _linkedMaterialsByDocument.clear();
    _linkedMaterials.clear();
    _sourceTopicId = null;
    _sourceTitle = null;
    _pendingSavedId = null;
    _boundAssetFingerprint = null;
    _historyCommitReceipt = null;
    _documentRevision = 0;
    _draftCreatedAt = DateTime.now().toUtc();
    _lastDocumentSignature = _documentSignature;
    _rememberLinkedMaterialsForDocument();
    _finishHydration(markClean: false);
  }

  String? _resolveSynchronizedDraftNoteId(CreationCanvasDraft draft) {
    return _clean(draft.boundNoteId) ?? _clean(draft.synchronizedNoteId);
  }

  bool _draftMatchesBoundAsset(CreationCanvasDraft draft) {
    final boundId = _resolveSynchronizedDraftNoteId(draft);
    if (boundId == null) {
      return draft.title.trim().isEmpty &&
          draft.markdown.trim().isEmpty &&
          draft.scriptDraftReceipt == null;
    }
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(boundId);
    if (note == null) return false;
    return _noteMatchesCanvasSnapshot(
      note,
      title: draft.title,
      markdown: draft.markdown,
      linkedMaterials: draft.linkedMaterials,
    );
  }

  bool _boundDraftBaseStillCurrent(CreationCanvasDraft draft) {
    final boundId = _resolveSynchronizedDraftNoteId(draft);
    if (boundId == null) return true;
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(boundId);
    if (note == null) return false;
    final fingerprint = _clean(draft.boundAssetFingerprint);
    if (fingerprint == null) return _draftMatchesBoundAsset(draft);
    return fingerprint == _canvasBoundAssetFingerprint(note);
  }

  Future<KnowledgeLibraryController?> _restoreCurrentKnowledgeLibrary({
    bool retryFailed = false,
  }) async {
    while (mounted) {
      final library = ref.read(knowledgeLibraryControllerProvider);
      final ready =
          library.cacheRestoreSucceeded ||
          await library.ensureCacheRestored(retryFailed: retryFailed);
      if (!mounted) return null;
      if (!identical(library, ref.read(knowledgeLibraryControllerProvider))) {
        continue;
      }
      return ready ? library : null;
    }
    return null;
  }

  bool _currentBoundAssetStillMatches() {
    final boundId = _clean(_pendingSavedId);
    if (boundId == null) return true;
    final fingerprint = _clean(_boundAssetFingerprint);
    if (fingerprint == null) return false;
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(boundId);
    return note != null && fingerprint == _canvasBoundAssetFingerprint(note);
  }

  bool _canvasSaveTargetMatches(
    V3FeedItem? note, {
    required String? fingerprint,
    required String markdown,
  }) {
    if (note == null ||
        note.isReadOnly ||
        note.syncState == NoteSyncState.conflict) {
      return false;
    }
    if (_canvasBoundAssetFingerprint(note) == fingerprint) return true;
    return note.syncState == NoteSyncState.synced &&
        note.remoteNoteId?.trim().isNotEmpty == true &&
        note.rawPartRevisionId?.trim().isNotEmpty == true &&
        note.rawBody.trim() == markdown.trim();
  }

  String _canvasBoundAssetFingerprint(V3FeedItem note) =>
      scriptDraftContentHash(
        jsonEncode(<String, Object?>{
          'id': note.id,
          'localRevision': note.localRevision,
          'title': note.title,
          'rawBody': note.rawBody,
          'linkedMaterials': <Map<String, Object?>>[
            for (final material in note.linkedMaterials)
              <String, Object?>{
                'id': material.id,
                'source': material.source.name,
                'title': material.title,
                'summary': material.summary,
              },
          ],
          'contentLineId': note.contentLineId,
          'contentLineName': note.contentLineName,
          'folderId': note.folderId,
          'folderName': note.folderName,
          'copiedFromContentId': note.copiedFromContentId,
          'publicUrl': note.publicUrl,
          'contentOrigin': note.contentOrigin.name,
          'topics': note.topics,
        }),
      );

  void _hydrateHistory(CreationCanvasHistoryEntry entry) {
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(entry.noteId);
    if (note == null || note.isReadOnly) {
      _failInitialDraft(
        note == null ? '原笔记已不存在，不能继续更新；不会自动另建笔记。' : '原笔记当前不可编辑。',
        entryLoadFailure: true,
      );
      return;
    }
    if (note.syncState == NoteSyncState.conflict) {
      _failInitialDraft('原笔记存在云端冲突，请先在资产中处理冲突。', entryLoadFailure: true);
      return;
    }
    if (_clean(note.remoteNoteId) != null &&
        note.syncState != NoteSyncState.synced &&
        !note.pendingRawOnlyUpdate) {
      _failInitialDraft(
        '这篇笔记还有其他未同步修改，请先在资产中完成同步，再继续编辑原始内容。',
        entryLoadFailure: true,
      );
      return;
    }
    if (note.rawBody.trim() == entry.markdown.trim()) {
      _hydrate(entry.toDraft());
      _title.text = note.title;
    } else {
      _hydrateInitialNote(note);
    }
    _pendingSavedId = entry.noteId;
    _boundAssetFingerprint = _canvasBoundAssetFingerprint(note);
    _linkedMaterials
      ..clear()
      ..addAll(note.linkedMaterials);
    _sourceTopicId = entry.sourceTopicId;
    _sourceTitle = entry.sourceTitle;
    _rememberLinkedMaterialsForDocument();
    _baselineSignature = _editorSignature;
  }

  bool _noteMatchesCanvasSnapshot(
    V3FeedItem note, {
    required String title,
    required String markdown,
    required Iterable<V3LinkedMaterialRef> linkedMaterials,
  }) =>
      note.source == V3MaterialSource.note &&
      note.title == _resolvedTitle(title, markdown) &&
      note.rawBody.trim() == markdown.trim() &&
      _sameCanvasLinkedMaterialIds(note.linkedMaterials, linkedMaterials);

  void _hydrateInitialNote(V3FeedItem note) {
    _automaticInitialNoteCreation = false;
    _automaticInitialNoteCreationScheduled = false;
    _title.text = note.title;
    Document document;
    final markdown = note.rawBody;
    try {
      document = _documentCodec.documentFromMarkdown(markdown);
    } on FormatException {
      document = Document()..insert(0, markdown);
    }
    _replaceBodyDocument(
      document,
      TextSelection.collapsed(offset: math.max(0, document.length - 1)),
    );
    _body.document.history.clear();
    _linkedMaterials
      ..clear()
      ..addAll(note.linkedMaterials);
    _sourceTopicId = null;
    _sourceTitle = null;
    _pendingSavedId = note.id;
    _boundAssetFingerprint = _canvasBoundAssetFingerprint(note);
    _draftCreatedAt = note.createdAt.toUtc();
    _documentRevision = 0;
    _lastDocumentSignature = _documentSignature;
    _rememberLinkedMaterialsForDocument();
    _finishHydration(markClean: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCanvasSnack('已载入原笔记当前的原始内容');
    });
  }

  void _finishHydration({required bool markClean}) {
    _hydrating = false;
    _lastDocumentSignature = _documentSignature;
    _rememberLinkedMaterialsForDocument();
    _baselineSignature = markClean ? _editorSignature : '';
    _bootstrapPhase = _CanvasBootstrapPhase.ready;
  }

  void _handleTitleChanged() {
    if (_hydrating) return;
    _savedDraftCleanupPending = false;
    _markDraftStateChanged();
    _autosaveCoordinator.schedule();
    if (mounted) setState(() {});
  }

  void _handleEditorFocusChanged() {
    if (_titleFocus.hasFocus) {
      _activeEditorTarget = _CanvasEditorTarget.title;
    } else if (_bodyFocus.hasFocus) {
      _activeEditorTarget = _CanvasEditorTarget.body;
      _scheduleCaretReveal(settledFrames: 4);
    }
    if (mounted) setState(() {});
  }

  void _handleBodyControllerChanged() {
    _scheduleEditorRefresh();
    if (_inlineAiReview == null &&
        (_bodyFocus.hasFocus || _toolbarPanel == _CanvasToolbarPanel.ai) &&
        (_toolbarPanel != _CanvasToolbarPanel.none || _linkEditorVisible)) {
      _frozenBodySelection = _body.selection;
    }
    if (_toolbarPanel == _CanvasToolbarPanel.ai && _inlineAiReview == null) {
      _aiEditScope = _body.selection.isCollapsed
          ? CanvasAiEditScope.global
          : CanvasAiEditScope.local;
    }
    if (_inlineAiReview == null &&
        _bodyFocus.hasFocus &&
        _body.selection.isCollapsed) {
      _scheduleCaretReveal();
    }
  }

  bool _preserveSelectedEditorFocus(UserScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final review = _inlineAiReview;
    if (review != null) {
      return _reviewFocus.hasFocus && !review.editor.selection.isCollapsed;
    }
    return _bodyFocus.hasFocus && !_body.selection.isCollapsed;
  }

  void _toggleKeyboard() {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    final focus = _activeEditorTarget == _CanvasEditorTarget.title
        ? _titleFocus
        : _bodyFocus;
    focus.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    if (_activeEditorTarget == _CanvasEditorTarget.body) {
      _scheduleCaretReveal();
    }
  }

  void _scheduleCaretReveal({int settledFrames = 2}) {
    if (_caretRevealScheduled) return;
    _caretRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretRevealScheduled = false;
      if (!mounted || !_canvasScroll.hasClients) return;
      final reviewing = _inlineAiReview != null;
      final focus = reviewing ? _reviewFocus : _bodyFocus;
      if (!focus.hasFocus) return;
      final editor = _inlineAiReview?.editor ?? _body;
      final selection = editor.selection;
      if (!selection.isValid || !selection.isCollapsed) return;
      final media = MediaQuery.of(context);
      final keyboardInset = media.viewInsets.bottom;
      if (keyboardInset <= 0) return;
      final renderEditor = (reviewing ? _reviewEditorKey : _bodyEditorKey)
          .currentState
          ?.renderEditor;
      if (renderEditor != null) {
        final maxOffset = math.max(0, editor.document.length - 1);
        final caretOffset = selection.extentOffset.clamp(0, maxOffset).toInt();
        final localCaret = renderEditor.getLocalRectForCaret(
          TextPosition(offset: caretOffset),
        );
        final globalTop = renderEditor.localToGlobal(localCaret.topLeft).dy;
        final globalBottom = renderEditor
            .localToGlobal(localCaret.bottomLeft)
            .dy;
        final visibleTop = media.padding.top + 72;
        final toolbarHeight = _bottomCommandInset;
        final visibleBottom =
            media.size.height - keyboardInset - toolbarHeight - 12;
        if (visibleBottom > visibleTop) {
          final delta = globalTop < visibleTop
              ? globalTop - visibleTop
              : globalBottom > visibleBottom
              ? globalBottom - visibleBottom
              : 0.0;
          final target = (_canvasScroll.offset + delta)
              .clamp(
                _canvasScroll.position.minScrollExtent,
                _canvasScroll.position.maxScrollExtent,
              )
              .toDouble();
          if ((_canvasScroll.offset - target).abs() >= 2) {
            _canvasScroll.animateTo(
              target,
              duration: V3MotionTokens.responsive,
              curve: Curves.easeOutCubic,
            );
          }
        }
      }
      if (settledFrames > 0) {
        _scheduleCaretReveal(settledFrames: settledFrames - 1);
      }
    });
  }

  void _handleBodyDocumentChanged(DocChange change) {
    if (_unreadableStructuredDraft && change.source == ChangeSource.local) {
      _unreadableStructuredDraft = false;
      _setAutosaveFailed(false, notify: false);
    }
    if (change.source == ChangeSource.local) {
      _savedDraftCleanupPending = false;
      if (_canvasAiController.status == CanvasAiTransformStatus.failed) {
        _canvasAiController.reset();
        _activeAiTarget = null;
      }
    }
    _synchronizeDocumentState();
    if (_inlineAiReview != null &&
        _canvasAiController.status == CanvasAiTransformStatus.previewing &&
        _activeAiTarget?.documentJson != _documentSignature) {
      _canvasAiController.invalidatePreviewSource();
      _clearInlineAiReview();
    }
    _scheduleEditorRefresh();
  }

  void _scheduleEditorRefresh() {
    if (_editorRefreshScheduled || !mounted) return;
    _editorRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editorRefreshScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _synchronizeDocumentState({bool scheduleAutosave = true}) {
    final currentDocumentSignature = _documentSignature;
    if (currentDocumentSignature == _lastDocumentSignature) return;
    if (!_hydrating) {
      _documentRevision += 1;
      _markDraftStateChanged();
      final remembered = _linkedMaterialsByDocument[currentDocumentSignature];
      if (remembered != null) {
        _linkedMaterials
          ..clear()
          ..addAll(remembered);
      }
      if (scheduleAutosave) _autosaveCoordinator.schedule();
    }
    _lastDocumentSignature = currentDocumentSignature;
  }

  void _listenToBodyDocument() {
    unawaited(_bodyChanges?.cancel());
    _bodyChanges = _body.changes.listen(_handleBodyDocumentChanged);
  }

  void _replaceBodyDocument(Document document, TextSelection selection) {
    unawaited(_bodyChanges?.cancel());
    _body.document = document;
    _body.updateSelection(selection, ChangeSource.remote);
    _lastDocumentSignature = _documentSignature;
    _listenToBodyDocument();
  }

  void _handleCanvasScroll() {
    for (final editorState in <EditorState?>[
      _bodyEditorKey.currentState,
      _reviewEditorKey.currentState,
    ]) {
      editorState?.selectionOverlay?.updateForScroll();
      editorState?.hideToolbar(false);
    }
    ContextMenuController.removeAny();
    _clearSelectedImage();
  }

  void _persistDraft({bool notify = true}) {
    _markDraftStateChanged();
    unawaited(_persistDraftDeferred(notify: notify));
  }

  Future<bool> _persistDraftDeferred({bool notify = true}) async {
    if (_hydrating || _allowLeave || _draftPersistenceSuppressed) return true;
    if (_unreadableStructuredDraft) {
      _setAutosaveFailed(true, notify: notify);
      return false;
    }
    _synchronizeDocumentState(scheduleAutosave: false);
    final persistenceEpoch = _draftStateEpoch;
    final persistenceSessionId = _sessionId;
    final title = _title.text;
    try {
      final markdown = _bodyMarkdown;
      final draft = _draftForPersistence(title: title, markdown: markdown);
      final clearCleanRecovery = !_isDirty && !_mustRetainCleanRecoveryDraft;
      final snapshot = clearCleanRecovery ? null : draft;
      if (snapshot?.historyCommitReceipt != null) {
        _recordCanvasState('save_receipt_persist_started');
      }
      final write = _draftPersistence.persist(snapshot);
      await write;
      _recordCanvasState(
        'draft_persisted',
        metadata: {
          'persisted_session_id': persistenceSessionId,
          'persisted_epoch': persistenceEpoch,
          'persisted_revision': snapshot?.revision,
          'persisted_save_phase': snapshot?.historyCommitReceipt?.phase.name,
          'cleared': snapshot == null,
        },
      );
      if (!mounted ||
          _sessionId != persistenceSessionId ||
          _draftStateEpoch != persistenceEpoch) {
        return true;
      }
      _draftRecoveryPresent = snapshot != null;
      var confirmationChanged = false;
      if (_draftStateEpoch == persistenceEpoch) {
        confirmationChanged = _confirmedDraftStateEpoch != persistenceEpoch;
        _confirmedDraftStateEpoch = persistenceEpoch;
      }
      _setAutosaveFailed(false, notify: notify);
      if (confirmationChanged && notify && mounted && !_autosaveFailed) {
        setState(() {});
      }
      return true;
    } catch (error) {
      _recordCanvasState(
        'draft_persist_failed',
        failed: true,
        metadata: {
          'persisted_session_id': persistenceSessionId,
          'persisted_epoch': persistenceEpoch,
          'error_type': error.runtimeType.toString(),
        },
      );
      if (mounted &&
          _sessionId == persistenceSessionId &&
          _draftStateEpoch == persistenceEpoch) {
        _setAutosaveFailed(true, notify: notify);
      }
      return false;
    }
  }

  bool get _mustRetainCleanRecoveryDraft =>
      _savedDraftCleanupPending ||
      _historyCommitReceipt != null ||
      _chatThreadId != null ||
      _pendingChatRewriteTurn != null ||
      _chatRewriteReceipts.isNotEmpty ||
      _scriptDraftReceipt != null;

  bool get _requiresLeaveSettlement =>
      _isDirty ||
      _linkEditorVisible ||
      _interactionPolicy.aiNeedsResolution ||
      _historyCommitReceipt != null ||
      _savedDraftCleanupPending ||
      _autosaveFailed ||
      _draftStateEpoch != _confirmedDraftStateEpoch ||
      (_draftRecoveryPresent && !_mustRetainCleanRecoveryDraft);

  void _markDraftStateChanged() {
    _draftStateEpoch += 1;
  }

  CreationCanvasDraft? _draftForPersistence({
    required String title,
    required String markdown,
  }) => buildCanvasAutosaveDraft(
    title: title,
    markdown: markdown,
    documentJson: _documentJson,
    documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
    linkedMaterials: _linkedMaterials,
    sourceTopicId: _sourceTopicId,
    sourceTitle: _sourceTitle,
    synchronizedNoteId: null,
    sessionId: _sessionId,
    entryIdentity: _entryIdentity,
    scriptDraftReceipt: _scriptDraftReceipt,
    boundNoteId: _clean(_pendingSavedId),
    boundAssetFingerprint: _clean(_boundAssetFingerprint),
    savedDraftCleanupPending: _savedDraftCleanupPending,
    chatThreadId: _clean(_chatThreadId),
    historyCommitReceipt: _historyCommitReceipt,
    chatRewriteReceipts: _chatReceiptsForPersistence(),
    revision: _documentRevision,
    createdAt: _draftCreatedAt,
    now: DateTime.now().toUtc(),
  );

  Future<bool> _clearPersistedDraftDeferred({bool notify = true}) async {
    _draftPersistenceSuppressed = true;
    _draftClearInProgress = true;
    _autosaveCoordinator.cancelPersist();
    final clearSessionId = _sessionId;
    final clearEpoch = _draftStateEpoch;
    try {
      await _draftPersistence.persist(null);
      if (!mounted || _sessionId != clearSessionId) return true;
      _draftRecoveryPresent = false;
      if (_draftStateEpoch == clearEpoch) {
        _confirmedDraftStateEpoch = clearEpoch;
      }
      _setAutosaveFailed(false, notify: notify);
      _recordCanvasState('draft_cleared');
      return true;
    } catch (_) {
      _draftPersistenceSuppressed = false;
      _setAutosaveFailed(true, notify: notify);
      return false;
    } finally {
      _draftClearInProgress = false;
    }
  }

  void _setAutosaveFailed(bool value, {required bool notify}) {
    if (_autosaveFailed == value) return;
    _autosaveFailed = value;
    _recordCanvasState('draft_write_state_changed', failed: value);
    if (notify && mounted) setState(() {});
  }

  Future<void> _confirmAndSave({
    bool requireConfirmation = true,
    bool? stayOnCanvasAfterSave,
  }) async {
    if (_saveConfirmationOpen) return;
    if (_saveInteractionLocked) {
      _showInteractionLocked();
      return;
    }
    if (_savedDraftCleanupPending && _historyCommitReceipt == null) {
      await _retrySavedDraftCleanup();
      return;
    }
    if (_ownsVoiceCapture) {
      if (_voiceState.isBusy) {
        _showCanvasSnack('语音输入正在处理中，请稍后保存');
        return;
      }
      await _toggleCanvasVoice();
      if (!mounted) return;
      if (_ownsVoiceCapture) {
        _showCanvasSnack('请先结束语音输入，再保存');
        return;
      }
    }
    final library = ref.read(knowledgeLibraryControllerProvider);
    final knowledgeReady = await library.ensureCacheRestored(retryFailed: true);
    if (!mounted) return;
    if (!knowledgeReady) {
      _showCanvasSnack('资产数据暂时无法读取，草稿仍保留，请重试保存');
      return;
    }
    _synchronizeDocumentState(scheduleAutosave: false);
    late final String markdown;
    try {
      markdown = _bodyMarkdown.trim();
    } on FormatException {
      _showCanvasSnack('正文中存在暂不支持的内容，请调整后重试');
      return;
    }
    final pendingHistory = _historyCommitReceipt;
    if (!_hasPendingSave || (pendingHistory == null && markdown.isEmpty)) {
      return;
    }
    final existingId = _clean(_pendingSavedId);
    final existingSnapshot = existingId == null
        ? null
        : library.noteForId(existingId);
    if (pendingHistory == null &&
        existingId != null &&
        existingSnapshot == null) {
      _showCanvasSnack('待保存笔记已不存在，内容仍保留');
      return;
    }
    final expectedFingerprint = _clean(_boundAssetFingerprint);
    if (pendingHistory == null &&
        existingSnapshot != null &&
        (expectedFingerprint == null ||
            expectedFingerprint !=
                _canvasBoundAssetFingerprint(existingSnapshot))) {
      _showCanvasSnack('资产已在其他位置更新，请重新打开后再保存');
      return;
    }
    final sourceTopic = _sourceTopicId == null
        ? null
        : library.noteForId(_sourceTopicId!);
    final editorLinkedMaterials = List<V3LinkedMaterialRef>.unmodifiable(
      _linkedMaterials,
    );
    final saveLinkedMaterials = pendingHistory != null
        ? editorLinkedMaterials
        : existingSnapshot != null
        ? List<V3LinkedMaterialRef>.unmodifiable(
            existingSnapshot.linkedMaterials,
          )
        : List<V3LinkedMaterialRef>.unmodifiable(
            _uniqueLinkedMaterials(<V3LinkedMaterialRef>[
              ...editorLinkedMaterials,
              if (sourceTopic != null)
                V3LinkedMaterialRef(
                  id: sourceTopic.id,
                  source: sourceTopic.source,
                  title: sourceTopic.title,
                ),
            ]).where((material) => material.id != existingId),
          );
    final title = pendingHistory == null
        ? existingSnapshot?.title ?? _resolvedTitle(_title.text, markdown)
        : _resolvedTitle(_title.text, markdown);
    final historyId =
        pendingHistory?.historyId ??
        _historyIdentityFromEntry(_entryIdentity) ??
        existingId;
    final editorAttempt = _CanvasSaveAttempt(
      rawTitle: _title.text,
      title: title,
      markdown: markdown,
      documentJson: _documentJson,
      documentRevision: _documentRevision,
      documentSignature: _documentSignature,
      editorSignature: _editorSignature,
      sourceTopicId: _sourceTopicId,
      sourceTitle: _sourceTitle,
      entryIdentity: _entryIdentity,
      sessionId: _sessionId,
      createdAt: _draftCreatedAt,
      existingId: existingId,
      expectedNote: existingSnapshot,
      expectedFingerprint: expectedFingerprint,
      editorLinkedMaterials: editorLinkedMaterials,
      saveLinkedMaterials: saveLinkedMaterials,
      historyId: historyId,
    );
    var attempt = editorAttempt;
    final frozenSnapshot = pendingHistory?.snapshot;
    if (frozenSnapshot != null) {
      try {
        attempt = editorAttempt.withFrozenSnapshot(frozenSnapshot);
      } on Object {
        _protectPendingHistoryTransaction('待提交快照无法校验，当前草稿与原提交记录均已保留。');
        return;
      }
    }
    if (pendingHistory != null &&
        !attempt.matchesPendingHistory(pendingHistory)) {
      _protectPendingHistoryTransaction('待提交版本与恢复记录不一致。为避免写入错误历史，原记录已保留。');
      return;
    }
    final confirmationMessage = pendingHistory != null
        ? [
            switch (pendingHistory.phase) {
              CreationCanvasHistoryCommitPhase.prepared =>
                '保存事务已恢复，确认后会安全完成笔记与创作历史提交。',
              CreationCanvasHistoryCommitPhase.noteCommitted =>
                '笔记正文已经落盘，确认后会补全创作历史并继续同步。',
              CreationCanvasHistoryCommitPhase.historyCommitted =>
                '创作历史已经落盘，确认后会重试云端保存。',
            },
            if (frozenSnapshot != null &&
                editorAttempt.editorSignature !=
                    attempt.committedEditorSignature)
              '本次仅提交上次已确认的版本；后续修改会保留在草稿中，需要再次保存。'
            else
              '云端确认后进入笔记详情。',
          ].join('\n\n')
        : existingId == null
        ? '确认后会在资产中创建一篇自由创作笔记。'
        : '仅更新这篇笔记的原始内容；标题、纲要、深度洞察及其他信息保持不变。';
    final shouldConfirm = requireConfirmation && !_automaticInitialNoteCreation;
    if (shouldConfirm) {
      await _dismissEditorKeyboard();
      if (!mounted) return;
      _saveConfirmationOpen = true;
      bool? confirmed;
      try {
        confirmed = await showV3GlassBottomSheet<bool>(
          context: context,
          builder: (sheetContext) => V3SheetScaffold(
            title: pendingHistory != null
                ? '继续完成保存？'
                : existingId == null
                ? '保存为新笔记？'
                : '保存当前修改？',
            message: confirmationMessage,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('确认保存'),
                  ),
                ),
              ],
            ),
          ),
        );
      } finally {
        _saveConfirmationOpen = false;
      }
      if (!mounted || confirmed != true) return;
    }
    if (!_saveAttemptStillCurrent(editorAttempt)) {
      _showCanvasSnack('正文已变化，请重新确认保存');
      return;
    }
    await _save(
      attempt,
      editorAttempt: editorAttempt,
      pendingHistory: pendingHistory,
      stayOnCanvasAfterSave:
          stayOnCanvasAfterSave ?? _automaticInitialNoteCreation,
    );
  }

  bool _saveAttemptStillCurrent(_CanvasSaveAttempt attempt) {
    _synchronizeDocumentState(scheduleAutosave: false);
    return _title.text == attempt.rawTitle &&
        _bodyMarkdown.trim() == attempt.markdown &&
        _documentJson == attempt.documentJson &&
        _documentRevision == attempt.documentRevision &&
        _editorSignature == attempt.editorSignature &&
        _sourceTopicId == attempt.sourceTopicId &&
        _sourceTitle == attempt.sourceTitle &&
        _entryIdentity == attempt.entryIdentity &&
        _sessionId == attempt.sessionId &&
        _clean(_pendingSavedId) == attempt.existingId &&
        _clean(_boundAssetFingerprint) == attempt.expectedFingerprint &&
        _sameCanvasLinkedMaterials(
          _linkedMaterials,
          attempt.editorLinkedMaterials,
        );
  }

  Future<void> _save(
    _CanvasSaveAttempt attempt, {
    required _CanvasSaveAttempt editorAttempt,
    required CreationCanvasHistoryCommitReceipt? pendingHistory,
    required bool stayOnCanvasAfterSave,
  }) async {
    if (_saveInteractionLocked) {
      _showInteractionLocked();
      return;
    }
    _autosaveCoordinator.cancelCloudSync();
    setState(() => _saving = true);
    _recordCanvasState('save_started');
    await _autosaveCoordinator.cancelPersistAndDrain();
    await _draftPersistence.drain();
    _recordCanvasState('draft_write_barrier_completed');
    if (!mounted) return;
    if (!_saveAttemptStillCurrent(editorAttempt) ||
        !identical(_historyCommitReceipt, pendingHistory)) {
      setState(() => _saving = false);
      _showCanvasSnack('正文已变化，请重新确认保存');
      return;
    }
    final library = ref.read(knowledgeLibraryControllerProvider);
    final draft = V3NoteDraft(
      title: attempt.title,
      rawBody: attempt.markdown,
      linkedMaterials: attempt.saveLinkedMaterials,
      contentLineId: attempt.expectedNote?.contentLineId,
      contentLineName: attempt.expectedNote?.contentLineName,
      folderId: attempt.expectedNote?.folderId,
      folderName: attempt.expectedNote?.folderName,
      topics: attempt.expectedNote?.topics ?? const <String>[],
    );
    KnowledgeManualNoteStage? noteStage;
    V3FeedItem? saved;
    var activeReceipt = pendingHistory;
    late final String committedNoteId;
    late final String committedTitle;
    late final DateTime committedCreatedAt;
    late final String committedSignature;
    var cachePersisted =
        activeReceipt != null &&
        activeReceipt.phase != CreationCanvasHistoryCommitPhase.prepared;
    var targetStale = false;
    try {
      if (activeReceipt?.phase == CreationCanvasHistoryCommitPhase.prepared) {
        final current = library.noteForId(activeReceipt!.noteId);
        if (current != null &&
            _canvasBoundAssetFingerprint(current) ==
                activeReceipt.noteFingerprint) {
          saved = current;
          cachePersisted = true;
          _pendingSavedId = activeReceipt.noteId;
          _boundAssetFingerprint = activeReceipt.noteFingerprint;
          activeReceipt = activeReceipt.advanceTo(
            CreationCanvasHistoryCommitPhase.noteCommitted,
          );
          _historyCommitReceipt = activeReceipt;
          _markDraftStateChanged();
          if (!await _persistDraftDeferred()) {
            throw StateError('CANVAS_NOTE_COMMIT_RECEIPT_PERSIST_FAILED');
          }
        }
      }
      if (activeReceipt == null ||
          activeReceipt.phase == CreationCanvasHistoryCommitPhase.prepared) {
        final preparedReceipt = activeReceipt;
        if (preparedReceipt != null) {
          final current = library.noteForId(preparedReceipt.noteId);
          final currentFingerprint = current == null
              ? null
              : _canvasBoundAssetFingerprint(current);
          if (currentFingerprint != preparedReceipt.noteFingerprint) {
            if (preparedReceipt.baseNoteId == null) {
              if (current != null) targetStale = true;
            } else if (current == null ||
                currentFingerprint != preparedReceipt.baseNoteFingerprint) {
              targetStale = true;
            }
            if (targetStale) {
              throw StateError('CANVAS_PREPARED_TARGET_CONFLICT');
            }
          }
        }

        Future<void> persistWriteAhead(V3FeedItem candidate) async {
          final candidateFingerprint = _canvasBoundAssetFingerprint(candidate);
          final receipt = CreationCanvasHistoryCommitReceipt(
            phase: CreationCanvasHistoryCommitPhase.prepared,
            historyId: attempt.historyIdFor(candidate.id),
            noteId: candidate.id,
            noteFingerprint: candidateFingerprint,
            editorSnapshotHash: attempt.snapshotHashForBound(candidate.id),
            snapshot: attempt.frozenSnapshot,
            baseNoteId: attempt.existingId,
            baseNoteFingerprint: attempt.expectedFingerprint,
          );
          _linkedMaterials
            ..clear()
            ..addAll(candidate.linkedMaterials);
          _rememberLinkedMaterialsForDocument();
          _historyCommitReceipt = receipt;
          activeReceipt = receipt;
          _markDraftStateChanged();
          if (!await _persistDraftDeferred()) {
            throw StateError('CANVAS_PREPARED_RECEIPT_PERSIST_FAILED');
          }
        }

        noteStage = attempt.existingId == null
            ? await library.stageManualNoteCreation(
                draft,
                createdAt: attempt.createdAt,
                contentOrigin: V3ContentOrigin.freeCreation,
                creationKey: attempt.sessionId,
                beforeMutation: preparedReceipt == null
                    ? persistWriteAhead
                    : null,
              )
            : await library.stageManualNoteUpdate(
                id: attempt.existingId!,
                draft: draft,
                expectedNote: attempt.expectedNote,
                rawOnly: true,
                beforeMutation: preparedReceipt == null
                    ? persistWriteAhead
                    : null,
              );
        saved = noteStage?.note;
        if (saved == null) {
          targetStale = attempt.existingId != null;
          throw StateError(
            targetStale
                ? 'CANVAS_NOTE_TARGET_STALE'
                : 'CANVAS_NOTE_STAGE_FAILED',
          );
        }
        activeReceipt = _historyCommitReceipt;
        final preparedAfterStage = activeReceipt;
        if (preparedAfterStage == null ||
            preparedAfterStage.phase !=
                CreationCanvasHistoryCommitPhase.prepared ||
            saved.id != preparedAfterStage.noteId ||
            _canvasBoundAssetFingerprint(saved) !=
                preparedAfterStage.noteFingerprint) {
          targetStale = true;
          throw StateError('CANVAS_PREPARED_TARGET_STALE');
        }
        final persisted = await library.flushPersistenceResult();
        if (!persisted) {
          await library.rollbackManualNoteStage(noteStage!);
          noteStage = null;
          throw StateError('CANVAS_NOTE_CACHE_SAVE_FAILED');
        }
        cachePersisted = true;
        if (!library.finalizeManualNoteStage(
          noteStage!,
          releaseToAutomaticSync: false,
        )) {
          targetStale = true;
          throw StateError('CANVAS_NOTE_STAGE_FINALIZE_FAILED');
        }
        noteStage = null;
        _pendingSavedId = saved.id;
        _boundAssetFingerprint = _canvasBoundAssetFingerprint(saved);
        _linkedMaterials
          ..clear()
          ..addAll(saved.linkedMaterials);
        _rememberLinkedMaterialsForDocument();
        activeReceipt = preparedAfterStage.advanceTo(
          CreationCanvasHistoryCommitPhase.noteCommitted,
        );
        _historyCommitReceipt = activeReceipt;
        _markDraftStateChanged();
        if (!await _persistDraftDeferred()) {
          throw StateError('CANVAS_NOTE_COMMIT_RECEIPT_PERSIST_FAILED');
        }
      }

      var committedReceipt = _historyCommitReceipt!;
      void verifyCommittedTarget() {
        if (!_canvasSaveTargetMatches(
          library.noteForId(committedReceipt.noteId),
          fingerprint: committedReceipt.noteFingerprint,
          markdown: attempt.markdown,
        )) {
          targetStale = true;
          throw StateError('CANVAS_COMMITTED_TARGET_CHANGED');
        }
      }

      verifyCommittedTarget();
      if (committedReceipt.phase ==
          CreationCanvasHistoryCommitPhase.noteCommitted) {
        final existingHistory = _historyPort.find(
          _historyUserScope,
          committedReceipt.historyId,
        );
        final historyNow = DateTime.now().toUtc();
        _recordCanvasState('history_write_started');
        await _historyPort.upsert(
          _historyUserScope,
          CreationCanvasHistoryEntry(
            id: committedReceipt.historyId,
            noteId: committedReceipt.noteId,
            title: attempt.title,
            markdown: attempt.markdown,
            documentJson: attempt.documentJson,
            documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
            revision: attempt.documentRevision,
            createdAt: existingHistory?.createdAt ?? attempt.createdAt,
            updatedAt: historyNow,
            linkedMaterials: attempt.saveLinkedMaterials,
            sourceTopicId: attempt.sourceTopicId,
            sourceTitle: attempt.sourceTitle,
          ),
        );
        committedReceipt = committedReceipt.advanceTo(
          CreationCanvasHistoryCommitPhase.historyCommitted,
        );
        _recordCanvasState('history_write_completed');
        activeReceipt = committedReceipt;
        _historyCommitReceipt = committedReceipt;
        _markDraftStateChanged();
        if (!await _persistDraftDeferred()) {
          throw StateError('CANVAS_HISTORY_COMMIT_RECEIPT_PERSIST_FAILED');
        }
      }
      if (committedReceipt.phase !=
          CreationCanvasHistoryCommitPhase.historyCommitted) {
        throw StateError('CANVAS_SAVE_PHASE_INVALID');
      }
      verifyCommittedTarget();
      _recordCanvasState('cloud_save_started');
      final synchronized = await library.syncNote(committedReceipt.noteId);
      _recordCanvasState(
        'cloud_save_result',
        metadata: {
          'outcome': synchronized.outcome.name,
          'error_code': synchronized.errorCode,
        },
      );
      if (!mounted) return;
      final cloudNote = synchronized.note;
      if (synchronized.outcome != KnowledgeNoteSyncOutcome.synced ||
          cloudNote?.remoteNoteId?.trim().isNotEmpty != true ||
          cloudNote?.rawPartRevisionId?.trim().isNotEmpty != true ||
          cloudNote!.rawBody.trim() != attempt.markdown.trim()) {
        throw StateError('CANVAS_CLOUD_SYNC_PENDING');
      }
      if (!await library.flushPersistenceResult()) {
        throw StateError('CANVAS_CLOUD_BINDING_PERSIST_FAILED');
      }
      if (!mounted) return;
      _synchronizeDocumentState(scheduleAutosave: false);
      _pendingSavedId = cloudNote.id;
      _boundAssetFingerprint = _canvasBoundAssetFingerprint(cloudNote);
      committedNoteId = committedReceipt.noteId;
      committedTitle = attempt.title;
      committedCreatedAt = attempt.createdAt;
      committedSignature = attempt.committedEditorSignature;
      _baselineSignature = committedSignature;
      _historyCommitReceipt = null;
      _savedDraftCleanupPending = true;
      _markDraftStateChanged();
    } on Object catch (error) {
      _recordCanvasState(
        'save_failed',
        failed: true,
        metadata: {
          'error_type': error.runtimeType.toString(),
          if (error is StateError &&
              error.message.toString().startsWith('CANVAS_'))
            'error_code': error.message.toString(),
        },
      );
      if (error is StateError &&
          error.message == 'MANUAL_NOTE_CREATION_KEY_CONFLICT') {
        targetStale = true;
      }
      final staged = noteStage;
      if (staged != null && !cachePersisted) {
        await library.rollbackManualNoteStage(staged);
      }
      if (_historyCommitReceipt case final receipt?) {
        if (receipt.phase == CreationCanvasHistoryCommitPhase.prepared) {
          _pendingSavedId = receipt.baseNoteId;
          _boundAssetFingerprint = receipt.baseNoteFingerprint;
        } else {
          _pendingSavedId = receipt.noteId;
          _boundAssetFingerprint = receipt.noteFingerprint;
        }
      } else if (cachePersisted && !targetStale && saved != null) {
        _pendingSavedId = saved.id;
        _boundAssetFingerprint = _canvasBoundAssetFingerprint(saved);
      } else {
        _pendingSavedId = attempt.existingId;
        _boundAssetFingerprint = attempt.expectedFingerprint;
      }
      if (!mounted) return;
      setState(() => _saving = false);
      await _persistDraftDeferred();
      if (!mounted) return;
      if (targetStale &&
          _historyCommitReceipt?.phase ==
              CreationCanvasHistoryCommitPhase.prepared) {
        _protectPendingHistoryTransaction('待保存资产已发生变化。为避免覆盖新内容，恢复记录已保留。');
        return;
      }
      _showCanvasSnack(
        targetStale
            ? '资产已在其他位置更新，内容仍保留'
            : error is StateError &&
                  error.message == 'CANVAS_CLOUD_SYNC_PENDING'
            ? '草稿和历史已保留，但云端尚未确认。请检查网络或资产冲突后重试，不会重复新建。'
            : cachePersisted
            ? '笔记已落盘，但提交尚未完成，请重试保存'
            : '保存失败，草稿已保留',
      );
      return;
    }

    if (!mounted) return;
    var postCommitWarning = false;
    try {
      if (!_profileActivityRecorded) {
        ref
            .read(profileHubControllerProvider)
            .recordActivity(
              V3ProfileActivity(
                id: 'creation-canvas-$committedNoteId',
                occurredAt: committedCreatedAt,
                type: V3ProfileActivityType.raw,
                title: committedTitle,
                feedItemId: committedNoteId,
                route: '/v3/feed/items/${Uri.encodeComponent(committedNoteId)}',
              ),
            );
        _profileActivityRecorded = true;
      }
    } on Object {
      postCommitWarning = true;
    }
    if (_editorSignature != committedSignature) {
      _automaticInitialNoteCreation = false;
      _automaticInitialNoteCreationScheduled = false;
      _scriptDraftReceipt = null;
      _savedDraftCleanupPending = false;
      setState(() => _saving = false);
      await _persistDraftDeferred();
      if (mounted) _showCanvasSnack('已保存上一版本，新的修改仍保留在草稿中');
      _schedulePendingEntryIntentTransition();
      return;
    }
    try {
      await _deleteUnusedOwnedCanvasImages();
    } on Object {
      postCommitWarning = true;
    }
    if (!mounted) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    if (_editorSignature != committedSignature) {
      _automaticInitialNoteCreation = false;
      _automaticInitialNoteCreationScheduled = false;
      _scriptDraftReceipt = null;
      _savedDraftCleanupPending = false;
      setState(() => _saving = false);
      await _persistDraftDeferred();
      if (mounted) _showCanvasSnack('已保存上一版本，新的修改仍保留在草稿中');
      _schedulePendingEntryIntentTransition();
      return;
    }
    final clearCheckpoint = _captureLeaveCheckpoint();
    final draftCleared = await _clearPersistedDraftDeferred();
    if (!mounted) return;
    if (!await _validateLeaveCheckpoint(clearCheckpoint)) {
      if (!mounted) return;
      _savedDraftCleanupPending = false;
      setState(() => _saving = false);
      await _persistDraftDeferred();
      return;
    }
    if (!mounted) return;
    if (!draftCleared) {
      _savedDraftCleanupPending = true;
      setState(() => _saving = false);
      await _persistDraftDeferred();
      if (mounted) _showCanvasSnack('笔记已保存，本地草稿记录待清理');
      return;
    }
    _savedDraftCleanupPending = false;
    _automaticInitialNoteCreation = false;
    _automaticInitialNoteCreationScheduled = false;
    _scriptDraftReceipt = null;
    _draftPersistenceSuppressed = false;
    final hasQueuedEntry = _pendingEntryIntent != null;
    setState(() {
      _saving = false;
      _allowLeave = !stayOnCanvasAfterSave && !hasQueuedEntry;
    });
    if (postCommitWarning) _showCanvasSnack('笔记已保存，部分本地记录稍后补全');
    if (hasQueuedEntry) {
      _schedulePendingEntryIntentTransition();
      return;
    }
    if (stayOnCanvasAfterSave) {
      _showCanvasSnack('已创建新笔记，后续保存会更新这篇笔记');
      return;
    }
    context.pushReplacement(AppRoutePaths.feedItem(committedNoteId));
  }

  Future<void> _retrySavedDraftCleanup() async {
    if (!_savedDraftCleanupPending || _saving || _baseInteractionLocked) return;
    final checkpoint = _captureLeaveCheckpoint();
    if (_isDirty) {
      setState(() => _savedDraftCleanupPending = false);
      final persisted = await _persistDraftDeferred();
      if (!mounted) return;
      _showCanvasSnack(persisted ? '新的修改已保留在草稿中' : '草稿暂时无法保存，请重试');
      return;
    }
    final savedId = _clean(_pendingSavedId);
    if (savedId == null) return;
    final markdown = _bodyMarkdown.trim();
    final library = ref.read(knowledgeLibraryControllerProvider);
    _autosaveCoordinator.cancelCloudSync();
    setState(() => _saving = true);
    try {
      await _autosaveCoordinator.cancelPersistAndDrain();
      await _draftPersistence.drain();
      if (!mounted) return;
      if (!await _validateLeaveCheckpoint(checkpoint) || !mounted) return;
      if (!_canvasSaveTargetMatches(
        library.noteForId(savedId),
        fingerprint: _boundAssetFingerprint,
        markdown: markdown,
      )) {
        _showCanvasSnack('资产已在其他位置更新，草稿仍保留，请先处理版本差异');
        return;
      }
      final synchronized = await library.syncNote(savedId);
      if (!mounted) return;
      final cloudNote = synchronized.note;
      if (synchronized.outcome != KnowledgeNoteSyncOutcome.synced ||
          cloudNote?.id != savedId ||
          cloudNote?.remoteNoteId?.trim().isNotEmpty != true ||
          cloudNote?.rawPartRevisionId?.trim().isNotEmpty != true ||
          cloudNote?.rawBody.trim() != markdown ||
          !await library.flushPersistenceResult()) {
        if (mounted) _showCanvasSnack('云端保存尚未完成，草稿仍保留，请稍后重试');
        return;
      }
      if (!mounted || !await _validateLeaveCheckpoint(checkpoint)) return;
      _boundAssetFingerprint = _canvasBoundAssetFingerprint(cloudNote!);
      final clearCheckpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred();
      if (!mounted) return;
      if (!await _validateLeaveCheckpoint(clearCheckpoint) || !mounted) return;
      if (!cleared) {
        await _persistDraftDeferred();
        if (mounted) _showCanvasSnack('本地草稿记录仍未清理，请重试');
        return;
      }
      final stayOnCanvas = _automaticInitialNoteCreation;
      _automaticInitialNoteCreation = false;
      _automaticInitialNoteCreationScheduled = false;
      _scriptDraftReceipt = null;
      _draftPersistenceSuppressed = false;
      final hasQueuedEntry = _pendingEntryIntent != null;
      setState(() {
        _savedDraftCleanupPending = false;
        _allowLeave = !stayOnCanvas && !hasQueuedEntry;
      });
      if (hasQueuedEntry) return;
      if (stayOnCanvas) {
        _showCanvasSnack('已创建新笔记，后续保存会更新这篇笔记');
        return;
      }
      context.pushReplacement(AppRoutePaths.feedItem(savedId));
    } on Object {
      if (!mounted) return;
      _draftPersistenceSuppressed = false;
      await _persistDraftDeferred();
      if (mounted) _showCanvasSnack('保存收尾暂未完成，草稿仍保留，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showAiTools({bool allowEmpty = false}) async {
    if (_aiToolsSheetOpen) return;
    if (_interactionLocked || !_interactionPolicy.canStartAi) {
      _showInteractionLocked();
      return;
    }
    if (!_ensureBodyEditor()) return;
    if (!await _settleCanvasVoiceBeforeSnapshot()) return;
    if (!mounted || _interactionLocked) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    if (!allowEmpty && _bodyIsEmpty) {
      _showCanvasSnack('先写下一些内容，再使用 AI 创作工具');
      _bodyFocus.requestFocus();
      return;
    }
    _freezeBodySelection();
    final hasSelection = !_normalizedBodySelection(useFrozen: true).isCollapsed;
    await _dismissEditorKeyboard();
    if (!mounted) return;
    _aiToolsSheetOpen = true;
    _CanvasAiToolChoice? choice;
    try {
      choice = await showV3GlassBottomSheet<_CanvasAiToolChoice>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _CanvasAiToolSheet(
          hasSelection: hasSelection,
          initialScope: hasSelection
              ? CanvasAiEditScope.local
              : CanvasAiEditScope.global,
        ),
      );
    } finally {
      _aiToolsSheetOpen = false;
    }
    if (!mounted || choice == null) return;
    _aiEditScope = choice.editScope;
    await _awaitSheetDismissal();
    if (!mounted) return;
    await _prepareAndRunAction(choice.action, editScope: choice.editScope);
  }

  Future<void> _prepareAndRunAction(
    CanvasAiAction action, {
    required CanvasAiEditScope editScope,
  }) async {
    if (_interactionLocked || !_ensureBodyEditor()) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    final sourceSession = _sessionId;
    final sourceRevision = _documentRevision;
    final sourceSignature = _documentSignature;
    final openingVariant = action == CanvasAiAction.openingOptimization
        ? await _selectOpeningVariant()
        : null;
    if (!mounted ||
        (action == CanvasAiAction.openingOptimization &&
            openingVariant == null)) {
      return;
    }
    final imageVariant = action == CanvasAiAction.imageBrief
        ? await _selectImageVariant()
        : null;
    if (!mounted ||
        (action == CanvasAiAction.imageBrief && imageVariant == null)) {
      return;
    }
    CanvasRelationTarget? relationTarget;
    if (action == CanvasAiAction.socialRelationShift) {
      relationTarget = await _selectRelationPerspective();
      if (!mounted || relationTarget == null) return;
    }
    String? personaContext;

    if (action == CanvasAiAction.personaInsertion) {
      var positioning = ref.read(deepPositioningControllerProvider);
      var draft = positioning.draft;
      var report = positioning.result?.markdown.trim();
      if (report?.isEmpty != false && !draft.isValid) {
        final destination = await showV3ActionSheet<String>(
          context: context,
          title: '需要先完成定位对话',
          message: '人设植入会使用社媒定位对话中形成的方向和价值信息。',
          items: const [
            V3ActionSheetItem(
              value: 'positioning',
              icon: Icons.person_search_outlined,
              label: '开始定位对话',
            ),
          ],
        );
        if (!mounted || destination == null) return;
        await _awaitSheetDismissal();
        if (!mounted) return;
        final navigation = await _pushCanvasOwnedRouteForResult<void>(
          '/v3/feed/chat?skill=social-positioning&purpose=deep-positioning',
        );
        if (!navigation.opened) return;
        if (!mounted) return;
        positioning = ref.read(deepPositioningControllerProvider);
        draft = positioning.draft;
        report = positioning.result?.markdown.trim();
        if (report?.isEmpty != false && !draft.isValid) {
          _showCanvasSnack('完成一次定位对话后再使用此工具');
          return;
        }
      }
      personaContext = report?.isNotEmpty == true
          ? report
          : [
              draft.identity,
              draft.industry,
              draft.expertise,
              draft.targetAudience,
              draft.value,
              draft.accountGoal,
              draft.commonExpressions,
            ].where((value) => value.trim().isNotEmpty).join('；');
    }

    if (!mounted || _interactionLocked) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    if (_sessionId != sourceSession ||
        _documentRevision != sourceRevision ||
        _documentSignature != sourceSignature) {
      _showCanvasSnack('正文已变化，请重新选择后生成');
      return;
    }
    final target = _createAiTarget(editScope);
    if (target == null || target.markdown.trim().isEmpty) {
      _showCanvasSnack(
        editScope == CanvasAiEditScope.local ? '请先选择要处理的正文' : '当前范围没有可处理的正文',
      );
      return;
    }
    _activeAiTarget = target;
    final controller = _canvasAiController;
    final generating = controller.generate(
      action: action,
      documentMarkdown: target.markdown,
      documentRevision: _documentRevision,
      editScope: target.editScope,
      selectionStart: target.editScope == CanvasAiEditScope.local ? 0 : null,
      selectionEnd: target.editScope == CanvasAiEditScope.local
          ? target.markdown.length
          : null,
      openingVariant: openingVariant,
      imageVariant: imageVariant,
      relationTarget: relationTarget,
      personaContext: personaContext,
    );
    _recordAiTarget(controller.request, target);
    final generated = await generating;
    if (!mounted) return;
    if (generated ||
        controller.status == CanvasAiTransformStatus.failed ||
        controller.status == CanvasAiTransformStatus.awaitingCompletion) {
      await _showAiPreview();
    }
  }

  Future<CanvasOpeningVariant?> _selectOpeningVariant() =>
      showV3ActionSheet<CanvasOpeningVariant>(
        context: context,
        title: '选择开头方式',
        items: const <V3ActionSheetItem<CanvasOpeningVariant>>[
          V3ActionSheetItem<CanvasOpeningVariant>(
            value: CanvasOpeningVariant.labeling,
            icon: Icons.sell_outlined,
            label: '标签化',
          ),
          V3ActionSheetItem<CanvasOpeningVariant>(
            value: CanvasOpeningVariant.defamiliarization,
            icon: Icons.change_circle_outlined,
            label: '陌生化',
          ),
        ],
      );

  Future<CanvasImageVariant?> _selectImageVariant() =>
      showV3ActionSheet<CanvasImageVariant>(
        context: context,
        title: '选择配图方式',
        items: const <V3ActionSheetItem<CanvasImageVariant>>[
          V3ActionSheetItem<CanvasImageVariant>(
            value: CanvasImageVariant.sceneDesign,
            icon: Icons.image_outlined,
            label: '影像增强成品配图',
          ),
          V3ActionSheetItem<CanvasImageVariant>(
            value: CanvasImageVariant.spokenVisuals,
            icon: Icons.slideshow_outlined,
            label: '口播解释性画面',
          ),
        ],
      );

  Future<CanvasRelationTarget?> _selectRelationPerspective() =>
      showV3ActionSheet<CanvasRelationTarget>(
        context: context,
        title: '选择人称',
        items: const <V3ActionSheetItem<CanvasRelationTarget>>[
          V3ActionSheetItem<CanvasRelationTarget>(
            value: CanvasRelationTarget.peer,
            icon: Icons.radio_button_unchecked_rounded,
            label: '平等交流',
          ),
          V3ActionSheetItem<CanvasRelationTarget>(
            value: CanvasRelationTarget.friend,
            icon: Icons.radio_button_unchecked_rounded,
            label: '朋友分享',
          ),
          V3ActionSheetItem<CanvasRelationTarget>(
            value: CanvasRelationTarget.advisor,
            icon: Icons.radio_button_unchecked_rounded,
            label: '顾问建议',
          ),
          V3ActionSheetItem<CanvasRelationTarget>(
            value: CanvasRelationTarget.mentor,
            icon: Icons.radio_button_unchecked_rounded,
            label: '导师引导',
          ),
          V3ActionSheetItem<CanvasRelationTarget>(
            value: CanvasRelationTarget.customer,
            icon: Icons.radio_button_unchecked_rounded,
            label: '客户对话',
          ),
        ],
      );

  Future<void> _showAiPreview() async {
    if (!mounted) return;
    final controller = _canvasAiController;
    if (controller.status != CanvasAiTransformStatus.previewing) return;
    final target = _activeAiTarget;
    if (target == null ||
        target.documentJson != _documentSignature ||
        !controller.isPreviewCurrent(
          currentMarkdown: _markdownForRange(target.range),
          currentRevision: _documentRevision,
        )) {
      controller.invalidatePreviewSource();
      return;
    }
    if (_reviewRequestId == controller.request?.requestId &&
        _inlineAiReview != null) {
      return;
    }
    try {
      final edit = _aiTargetEdit(
        target.range,
        controller.result!.replacementMarkdown,
      );
      final candidate = _candidateForAiTarget(
        target.range,
        controller.result!.replacementMarkdown,
      );
      final lastCandidateOffset = math.max(
        0,
        _deltaContentLength(candidate) - 1,
      );
      final candidateCaret =
          (target.range.start + _deltaContentLength(edit.replacement))
              .clamp(0, lastCandidateOffset)
              .toInt();
      final review = CanvasAiInlineReview(
        base: _body.document.toDelta(),
        candidate: candidate,
        initialCandidateSelection: TextSelection.collapsed(
          offset: candidateCaret,
        ),
      );
      _bodyFocus.unfocus();
      _clearInlineAiReview();
      setState(() {
        _inlineAiReview = review;
        _reviewRequestId = controller.request!.requestId;
        _selectedImageId = null;
      });
    } on Object {
      controller.failPreviewRendering();
      _showCanvasSnack('建议暂时无法显示，原文已保留');
    }
  }

  void _clearInlineAiReview() {
    final review = _inlineAiReview;
    if (review == null) return;
    _reviewFocus.unfocus();
    setState(() {
      _inlineAiReview = null;
      _reviewRequestId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => review.dispose());
  }

  void _rejectAiPreview() {
    _clearInlineAiReview();
    _canvasAiController.reset();
    _activeAiTarget = null;
  }

  void _cancelAiProposal() {
    _clearInlineAiReview();
    _canvasAiController.cancel();
    _activeAiTarget = null;
  }

  bool _applyAiPreview() {
    _synchronizeDocumentState(scheduleAutosave: false);
    final controller = _canvasAiController;
    final target = _activeAiTarget;
    final review = _inlineAiReview;
    if (review == null ||
        controller.status != CanvasAiTransformStatus.previewing) {
      return false;
    }
    if (target == null ||
        target.documentJson != _documentSignature ||
        _reviewRequestId != controller.request?.requestId) {
      controller.invalidatePreviewSource();
      _clearInlineAiReview();
      _showCanvasSnack('正文已变化，请重新生成');
      return false;
    }
    try {
      final candidate = _documentCodec.normalizeDelta(review.candidateDelta);
      final selection = review.candidateSelection;
      final prospective = _documentCodec.normalizeDelta(
        _candidateForAiTarget(
          target.range,
          controller.result!.replacementMarkdown,
        ),
      );
      if (jsonEncode(prospective.toJson()) != jsonEncode(candidate.toJson())) {
        controller.failPreviewRendering();
        _clearInlineAiReview();
        _showCanvasSnack('建议已失效，正文保持不变');
        return false;
      }
      final application = controller.beginApply(
        currentMarkdown: _markdownForRange(target.range),
        currentRevision: _documentRevision,
      );
      if (application == null) {
        _clearInlineAiReview();
        _showCanvasSnack('正文已变化，请重新生成');
        return false;
      }
      if (!_commitAiCandidate(candidate, selection)) {
        controller.completeApply(succeeded: false);
        _clearInlineAiReview();
        _showCanvasSnack('建议暂时无法应用，正文已保留');
        return false;
      }
      _savedDraftCleanupPending = false;
      _synchronizeDocumentState();
      _clearInlineAiReview();
      controller.completeApply();
      _activeAiTarget = null;
      return true;
    } on Object {
      if (controller.status == CanvasAiTransformStatus.previewing) {
        controller.failPreviewRendering();
      } else {
        controller.completeApply(succeeded: false);
      }
      _clearInlineAiReview();
      _showCanvasSnack('建议暂时无法应用，正文已保留');
      return false;
    }
  }

  Future<void> _recoverAiProposal({required bool regenerate}) async {
    _synchronizeDocumentState(scheduleAutosave: false);
    final controller = _canvasAiController;
    final target = _activeAiTarget;
    if (target == null ||
        target.documentJson != _documentSignature ||
        controller.request?.documentRevision != _documentRevision) {
      _rejectAiPreview();
      _showCanvasSnack('正文已变化，请重新选择后生成');
      return;
    }
    await (regenerate ? controller.regenerate() : controller.retry());
    if (mounted) await _showAiPreview();
  }

  Widget _buildAiRecoverySheet(
    CanvasAiController controller,
  ) => V3GlassBottomSheet(
    showHandle: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .42,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.status ==
                CanvasAiTransformStatus.awaitingCompletion) ...[
              const Text(
                '任务仍在生成，正文未被修改。',
                key: ValueKey<String>('canvas-ai-awaiting-completion'),
              ),
              FilledButton(
                key: const ValueKey<String>('canvas-ai-continue-waiting'),
                onPressed: controller.canRetry
                    ? () => _recoverAiProposal(regenerate: false)
                    : null,
                child: const Text('继续等待'),
              ),
              TextButton(
                key: const ValueKey<String>('canvas-ai-cancel-waiting'),
                onPressed: _cancelAiProposal,
                child: const Text('取消生成'),
              ),
            ] else ...[
              _CanvasAiFailure(
                errorCode: controller.errorCode,
                onRetry: controller.canRetry
                    ? () => _recoverAiProposal(regenerate: false)
                    : null,
                onRegenerate: controller.canRegenerate && !controller.canRetry
                    ? () => _recoverAiProposal(regenerate: true)
                    : null,
              ),
              TextButton(onPressed: _rejectAiPreview, child: const Text('关闭')),
            ],
          ],
        ),
      ),
    ),
  );

  Future<void> _openCanvasChat() async {
    if (_interactionLocked || !_interactionPolicy.canOpenChat) {
      _showInteractionLocked();
      return;
    }
    if (!_ensureBodyEditor()) return;
    if (!await _settleCanvasVoiceBeforeSnapshot()) return;
    if (!mounted || _interactionLocked) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    final rewriteTarget = _createChatRewriteTarget();
    await _dismissEditorKeyboard();
    if (!mounted) return;
    final chatSessionId = _sessionId;
    final controller = ref.read(creationCanvasChatControllerProvider);
    final needsFreshThread =
        _canvasChatFreshResetPending ||
        (!_canvasChatStarted && _chatThreadId == null);
    if (!_canvasChatStarted) {
      _canvasChatSubscription?.close();
      _canvasChatSubscription = ref.listenManual<ChatController>(
        creationCanvasChatControllerProvider,
        (_, nextController) {
          _handleCanvasChatProviderChanged(
            nextController,
            sessionId: chatSessionId,
          );
        },
      );
    }
    _canvasChatStarted = true;
    if (needsFreshThread) _canvasChatFreshResetPending = true;
    _handleCanvasChatProviderChanged(controller, sessionId: chatSessionId);
    final startFresh = _canvasChatFreshResetPending;
    final wideLayout = MediaQuery.sizeOf(context).width >= 700;
    final panel = _CanvasChatPanel(
      documentContext: () => _sessionId == chatSessionId
          ? _chatDocumentContext(rewriteTarget)
          : '',
      rewriteTarget: rewriteTarget,
      startFresh: startFresh,
      showTopGlow: wideLayout,
      initialThreadId: _chatThreadId,
      captureRewriteBaseline: () => _sessionId == chatSessionId
          ? _captureChatRewriteBaseline(rewriteTarget)
          : null,
      rewriteBaselineForMessage: (messageId) => _sessionId == chatSessionId
          ? _chatRewriteReceipts[messageId]?.toBaseline()
          : null,
      pendingTurn: () =>
          _sessionId == chatSessionId ? _pendingChatRewriteTurn : null,
      onTurnPrepared: (baseline, userMessageId, requestText) =>
          _prepareCanvasChatTurn(
            baseline,
            userMessageId: userMessageId,
            requestText: requestText,
            sessionId: chatSessionId,
          ),
      onThreadReadyToSubmit: (threadId, userMessageId) =>
          _checkpointCanvasChatMessageSubmission(
            threadId: threadId,
            userMessageId: userMessageId,
            sessionId: chatSessionId,
          ),
      onMessageKnownRejected: (userMessageId) =>
          _markCanvasChatMessageKnownRejected(
            userMessageId,
            sessionId: chatSessionId,
          ),
      onTurnAccepted: (threadId, userMessageId, agentRunId, acceptedUserId) {
        _bindCanvasChatTurn(
          threadId: threadId,
          userMessageId: userMessageId,
          agentRunId: agentRunId,
          acceptedUserMessageId: acceptedUserId,
          sessionId: chatSessionId,
        );
      },
      onTurnAbandoned: (userMessageId) {
        return _abandonCanvasChatTurn(userMessageId, sessionId: chatSessionId);
      },
      onRejectedTurnEnd: (userMessageId) {
        return _endRejectedCanvasChatTurn(
          userMessageId,
          sessionId: chatSessionId,
        );
      },
      onThreadChanged: (threadId) {
        if (!mounted || _sessionId != chatSessionId) return;
        if (_chatThreadId == threadId) return;
        _chatThreadId = threadId;
        _persistDraft(notify: false);
      },
      onUseSkill: (action, baseline) async {
        if (!mounted || _sessionId != chatSessionId || _interactionLocked) {
          return;
        }
        _synchronizeDocumentState(scheduleAutosave: false);
        if (baseline.documentHash !=
                scriptDraftContentHash(_documentSignature) ||
            baseline.documentRevision != _documentRevision) {
          _showCanvasSnack('正文已变化，请重新选择范围');
          return;
        }
        _body.updateSelection(
          TextSelection(
            baseOffset: baseline.range.start,
            extentOffset: baseline.range.end,
          ),
          ChangeSource.local,
        );
        _freezeBodySelection();
        await _prepareAndRunAction(action, editScope: baseline.editScope);
      },
      onProposeRewrite: (suggestion, baseline) {
        if (!mounted || _sessionId != chatSessionId) return;
        unawaited(_startChatRewriteProposal(suggestion, baseline: baseline));
      },
      onOpenTask: (taskId) async {
        await _awaitSheetDismissal();
        if (!mounted || _sessionId != chatSessionId) return;
        await _pushCanvasOwnedRoute(
          '/v3/workbench/tasks/${Uri.encodeComponent(taskId)}',
        );
      },
    );
    if (wideLayout) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭创作聊天',
        barrierColor: Theme.of(
          context,
        ).colorScheme.shadow.withValues(alpha: .22),
        transitionDuration: V3MotionTokens.resolve(
          context,
          V3MotionTokens.standard,
        ),
        pageBuilder: (dialogContext, _, __) => Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            final tokens = HuahuoV3Theme.tokensOf(context);
            final availableHeight =
                media.size.height - media.viewInsets.bottom - 24;
            final panelHeight = availableHeight.clamp(0.0, 720.0);
            return AnimatedPadding(
              duration: V3MotionTokens.resolve(
                context,
                V3MotionTokens.standard,
              ),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Material(
                      color: tokens.surface,
                      elevation: 16,
                      shadowColor: Colors.black.withValues(alpha: .28),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: tokens.line),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: 420,
                        height: panelHeight,
                        child: panel,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      return;
    }
    await showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      topAccent: const _CanvasChatLuminousEdge(),
      builder: (context) {
        final media = MediaQuery.of(context);
        final targetHeight = media.size.height * .58;
        final availableHeight =
            media.size.height - media.viewInsets.bottom - 36;
        final panelHeight = availableHeight < targetHeight
            ? availableHeight.clamp(0.0, targetHeight)
            : targetHeight;
        return AnimatedPadding(
          duration: V3MotionTokens.standard,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SizedBox(height: panelHeight, child: panel),
        );
      },
    );
  }

  String _chatDocumentContext([_CanvasChatRewriteTarget? rewriteTarget]) {
    if (rewriteTarget != null) {
      return [
        if (_title.text.trim().isNotEmpty) '# ${_title.text.trim()}',
        '## 当前选中文字（仅改写该范围）',
        rewriteTarget.sourceText,
        if (rewriteTarget.contextText != rewriteTarget.sourceText) ...[
          '## 所在段落（仅供理解）',
          rewriteTarget.contextText,
        ],
      ].join('\n\n').trim();
    }
    final value = [
      if (_title.text.trim().isNotEmpty) '# ${_title.text.trim()}',
      _bodyMarkdown.trim(),
    ].join('\n\n').trim();
    return value;
  }

  _CanvasChatRewriteTarget? _createChatRewriteTarget() {
    final selection = _normalizedBodySelection();
    if (selection.isCollapsed) return null;
    final plainText = _body.document.toPlainText();
    final maxOffset = math.max(0, _body.document.length - 1);
    final range = _CanvasRichRange(start: selection.start, end: selection.end);
    final sourceText = plainText.substring(range.start, range.end);
    if (sourceText.trim().isEmpty) return null;
    final contextStart = selection.start == 0
        ? 0
        : plainText.lastIndexOf('\n', selection.start - 1) + 1;
    final boundary = plainText.indexOf(
      '\n',
      math.max(selection.start, selection.end - 1),
    );
    final contextEnd = boundary < 0
        ? maxOffset
        : math.min(maxOffset, boundary + 1);
    return _CanvasChatRewriteTarget(
      range: range,
      sourceText: sourceText,
      contextText: plainText.substring(contextStart, contextEnd),
      documentSignature: _documentSignature,
      documentRevision: _documentRevision,
    );
  }

  _CanvasChatRewriteBaseline? _captureChatRewriteBaseline(
    _CanvasChatRewriteTarget? rewriteTarget,
  ) {
    _synchronizeDocumentState(scheduleAutosave: false);
    final documentSignature = _documentSignature;
    final documentRevision = _documentRevision;
    late final _CanvasRichRange range;
    late final String sourceMarkdown;
    late final CanvasAiEditScope editScope;
    if (rewriteTarget == null) {
      range = _CanvasRichRange(
        start: 0,
        end: math.max(0, _body.document.length - 1),
      );
      sourceMarkdown = _bodyMarkdown;
      editScope = CanvasAiEditScope.global;
    } else {
      final plainText = _body.document.toPlainText();
      range = rewriteTarget.range;
      final targetStillCurrent =
          rewriteTarget.documentSignature == documentSignature &&
          rewriteTarget.documentRevision == documentRevision &&
          range.start >= 0 &&
          range.end >= range.start &&
          range.end <= plainText.length &&
          plainText.substring(range.start, range.end) ==
              rewriteTarget.sourceText;
      if (!targetStillCurrent) return null;
      sourceMarkdown = _markdownForRange(range);
      editScope = CanvasAiEditScope.local;
    }
    if (sourceMarkdown.trim().isEmpty) return null;
    return _CanvasChatRewriteBaseline(
      range: range,
      sourceMarkdown: sourceMarkdown,
      sourceHash: scriptDraftContentHash(sourceMarkdown),
      chatContext: _chatDocumentContext(rewriteTarget),
      documentHash: scriptDraftContentHash(documentSignature),
      documentRevision: documentRevision,
      editScope: editScope,
    );
  }

  Future<bool> _prepareCanvasChatTurn(
    _CanvasChatRewriteBaseline baseline, {
    required String userMessageId,
    required String requestText,
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return false;
    if (_pendingChatRewriteTurn != null) {
      _showCanvasSnack('请先重试或结束上一次发送');
      return false;
    }
    _pendingChatRewriteTurn = _CanvasChatPendingRewriteTurn(
      baseline: baseline,
      threadId: _chatThreadId,
      userMessageId: userMessageId,
      agentRunId: null,
      requestText: requestText,
    );
    _markDraftStateChanged();
    final persisted = await _persistDraftDeferred(notify: false);
    if (!mounted || _sessionId != sessionId) return false;
    if (persisted) {
      setState(() {});
      return true;
    }
    if (_pendingChatRewriteTurn?.userMessageId == userMessageId) {
      _pendingChatRewriteTurn = null;
      _markDraftStateChanged();
    }
    _showCanvasSnack('聊天请求暂时无法安全保存，请重试');
    setState(() {});
    return false;
  }

  void _bindCanvasChatTurn({
    required String threadId,
    required String userMessageId,
    required String sessionId,
    String? agentRunId,
    String? acceptedUserMessageId,
  }) {
    if (!mounted || _sessionId != sessionId) return;
    final normalizedThreadId = _clean(threadId);
    final pending = _pendingChatRewriteTurn;
    if (normalizedThreadId == null ||
        pending == null ||
        pending.userMessageId != userMessageId) {
      return;
    }
    _pendingChatRewriteTurn = pending.bindTurn(
      threadId: normalizedThreadId,
      agentRunId: agentRunId,
      userMessageId: acceptedUserMessageId,
    );
    _chatThreadId = normalizedThreadId;
    _markDraftStateChanged();
    _persistDraft(notify: false);
    _handleCanvasChatControllerChanged(
      ref.read(creationCanvasChatControllerProvider),
      sessionId: sessionId,
    );
  }

  Future<bool> _checkpointCanvasChatMessageSubmission({
    required String threadId,
    required String userMessageId,
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return false;
    final normalizedThreadId = _clean(threadId);
    final pending = _pendingChatRewriteTurn;
    if (normalizedThreadId == null ||
        pending == null ||
        pending.userMessageId != userMessageId) {
      return false;
    }
    final prepared = pending
        .bindTurn(threadId: normalizedThreadId)
        .withSubmissionPhase(CreationCanvasChatSubmissionPhase.submitting);
    _pendingChatRewriteTurn = prepared;
    _chatThreadId = normalizedThreadId;
    _markDraftStateChanged();
    final persisted = await _persistDraftDeferred(notify: false);
    if (!mounted || _sessionId != sessionId) return false;
    if (persisted) {
      setState(() {});
      return true;
    }
    if (_pendingChatRewriteTurn?.userMessageId == userMessageId) {
      _pendingChatRewriteTurn = prepared.withSubmissionPhase(
        CreationCanvasChatSubmissionPhase.prepared,
      );
      _markDraftStateChanged();
    }
    _showCanvasSnack('聊天发送检查点暂时无法保存，请重试');
    setState(() {});
    return false;
  }

  Future<void> _markCanvasChatMessageKnownRejected(
    String userMessageId, {
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return;
    final pending = _pendingChatRewriteTurn;
    if (pending == null || pending.userMessageId != userMessageId) return;
    if (pending.submissionPhase == CreationCanvasChatSubmissionPhase.prepared) {
      return;
    }
    _pendingChatRewriteTurn = pending.withSubmissionPhase(
      CreationCanvasChatSubmissionPhase.prepared,
    );
    _markDraftStateChanged();
    final persisted = await _persistDraftDeferred(notify: false);
    if (!mounted || _sessionId != sessionId) return;
    if (!persisted) {
      _showCanvasSnack('发送结果已拒绝，但草稿状态暂未保存');
    }
    setState(() {});
  }

  Future<bool> _abandonCanvasChatTurn(
    String userMessageId, {
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return false;
    final pending = _pendingChatRewriteTurn;
    if (pending?.userMessageId != userMessageId) return false;
    _pendingChatRewriteTurn = null;
    _markDraftStateChanged();
    final persisted = await _persistDraftDeferred(notify: false);
    if (!mounted || _sessionId != sessionId) return false;
    if (!persisted) {
      if (_pendingChatRewriteTurn == null) {
        _pendingChatRewriteTurn = pending;
        _markDraftStateChanged();
      }
      _showCanvasSnack('发送状态暂时无法保存，请稍后重试');
      setState(() {});
      return false;
    }
    setState(() {});
    return true;
  }

  Future<bool> _prepareCanvasChatTurnForEnd(
    String userMessageId, {
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return false;
    final pending = _pendingChatRewriteTurn;
    if (pending?.userMessageId != userMessageId) return false;
    if (pending!.submissionPhase !=
        CreationCanvasChatSubmissionPhase.prepared) {
      _pendingChatRewriteTurn = pending.withSubmissionPhase(
        CreationCanvasChatSubmissionPhase.prepared,
      );
      _markDraftStateChanged();
    }
    final persisted = await _persistDraftDeferred(notify: false);
    if (!mounted || _sessionId != sessionId) return false;
    if (!persisted) {
      _showCanvasSnack('发送结束状态暂时无法保存，请稍后重试');
      setState(() {});
      return false;
    }
    setState(() {});
    return true;
  }

  Future<bool> _endRejectedCanvasChatTurn(
    String userMessageId, {
    required String sessionId,
  }) async {
    if (!mounted || _sessionId != sessionId) return false;
    final pending = _pendingChatRewriteTurn;
    if (pending?.userMessageId != userMessageId) return false;
    final controller = ref.read(creationCanvasChatControllerProvider);
    final controllerOwnsTurn =
        controller.state.turnState.userMessageId == userMessageId;
    final hasDurableNonAdmissionProof =
        pending!.submissionPhase == CreationCanvasChatSubmissionPhase.prepared;
    if (controllerOwnsTurn &&
        !controller.canAbandonFailedTextMessage(
          userMessageId,
          hasDurableNonAdmissionProof: hasDurableNonAdmissionProof,
        )) {
      return false;
    }
    if (!controllerOwnsTurn && !hasDurableNonAdmissionProof) {
      return false;
    }
    if (!await _prepareCanvasChatTurnForEnd(
      userMessageId,
      sessionId: sessionId,
    )) {
      return false;
    }
    if (controllerOwnsTurn) {
      final controllerCommitted = await controller.abandonFailedTextMessage(
        userMessageId,
        hasDurableNonAdmissionProof: true,
      );
      if (!mounted || _sessionId != sessionId) return false;
      if (!controllerCommitted) {
        _showCanvasSnack('聊天记录暂时无法结束，请稍后重试');
        setState(() {});
        return false;
      }
    }
    return _abandonCanvasChatTurn(userMessageId, sessionId: sessionId);
  }

  Future<bool> _settlePendingCanvasChatForDestructiveDiscard() async {
    final pending = _pendingChatRewriteTurn;
    if (pending == null) return true;
    _pendingChatRewriteTurn = null;
    _markDraftStateChanged();
    return true;
  }

  void _handleCanvasChatControllerChanged(
    ChatController controller, {
    required String sessionId,
  }) {
    if (!mounted || _sessionId != sessionId) return;
    final state = controller.state;
    final threadId = _clean(state.activeThreadId);
    if (threadId != null && threadId != _chatThreadId) {
      _chatThreadId = threadId;
      _persistDraft(notify: false);
    }

    var pending = _pendingChatRewriteTurn;
    if (pending == null) return;
    final turnUserId = state.turnState.userMessageId;
    final turnRunId = _clean(state.turnState.agentRunId);
    final sameRun =
        pending.agentRunId != null &&
        pending.agentRunId == turnRunId &&
        pending.threadId == threadId;
    final ownsTurn =
        sameRun ||
        (turnUserId == pending.userMessageId &&
            (pending.threadId == null || pending.threadId == threadId) &&
            (pending.agentRunId == null || pending.agentRunId == turnRunId));
    var changed = false;
    if (threadId != null && ownsTurn) {
      final needsBinding =
          pending.threadId != threadId ||
          pending.userMessageId != turnUserId ||
          (pending.agentRunId == null && turnRunId != null);
      if (needsBinding) {
        pending = pending.bindTurn(
          threadId: threadId,
          agentRunId: turnRunId,
          userMessageId: turnUserId,
        );
        _pendingChatRewriteTurn = pending;
        _chatThreadId = threadId;
        changed = true;
      }
    }
    if (pending.threadId == null || threadId != pending.threadId) return;
    final pendingRunId = pending.agentRunId;
    final assistantByRun = pendingRunId == null
        ? null
        : state.messages
              .where(
                (message) =>
                    message.role == ChatMessageRole.assistant &&
                    message.agentRunId == pendingRunId &&
                    message.status != 'streaming' &&
                    message.localDelivery != ChatLocalDeliveryState.pending,
              )
              .firstOrNull;
    final assistantMessageId =
        assistantByRun?.messageId ??
        (ownsTurn && state.turnState.phase == ChatTurnPhase.settled
            ? state.turnState.assistantMessageId
            : null);
    if (assistantMessageId != null) {
      final assistant = state.messages
          .where((message) => message.messageId == assistantMessageId)
          .firstOrNull;
      final belongsToAcceptedRun =
          pendingRunId == null ||
          assistant?.agentRunId == pendingRunId ||
          state.turnState.agentRunId == pendingRunId;
      if (assistant?.role == ChatMessageRole.assistant &&
          assistant?.status != 'streaming' &&
          assistant?.localDelivery != ChatLocalDeliveryState.pending &&
          belongsToAcceptedRun) {
        _chatRewriteReceipts[assistantMessageId] = pending.toReceipt(
          assistantMessageId: assistantMessageId,
        );
        _trimChatRewriteReceipts();
        _pendingChatRewriteTurn = null;
        changed = true;
        _recordCanvasState(
          'chat_turn_settled',
          metadata: {
            'thread_id': pending.threadId,
            'agent_run_id': pending.agentRunId,
            'user_message_id': pending.userMessageId,
            'assistant_message_id': assistantMessageId,
          },
        );
      }
    }
    if (ownsTurn &&
        state.turnState.phase == ChatTurnPhase.settled &&
        state.turnState.assistantMessageId == null) {
      _pendingChatRewriteTurn = null;
      changed = true;
    }
    if (changed) {
      _persistDraft(notify: false);
    }
  }

  void _handleCanvasChatProviderChanged(
    ChatController controller, {
    required String sessionId,
  }) {
    if (!mounted || _sessionId != sessionId) return;
    if (_canvasChatFreshResetPending) {
      if (controller.state.isSending) return;
      _canvasChatFreshResetPending = false;
      controller.startNewThread();
      return;
    }
    _handleCanvasChatControllerChanged(controller, sessionId: sessionId);
  }

  Future<void> _startChatRewriteProposal(
    String suggestion, {
    required _CanvasChatRewriteBaseline baseline,
  }) async {
    final normalizedSuggestion = suggestion.trim();
    if (normalizedSuggestion.isEmpty) return;
    if (_interactionLocked) {
      _showInteractionLocked();
      return;
    }
    if (!_ensureBodyEditor()) return;
    _synchronizeDocumentState(scheduleAutosave: false);
    final range = baseline.range;
    final rangeIsValid =
        range.start >= 0 &&
        range.end >= range.start &&
        range.end <= math.max(0, _body.document.length - 1);
    final currentMarkdown = rangeIsValid ? _markdownForRange(range) : null;
    final targetStillCurrent =
        rangeIsValid &&
        baseline.documentHash == scriptDraftContentHash(_documentSignature) &&
        baseline.documentRevision == _documentRevision &&
        currentMarkdown == baseline.sourceMarkdown &&
        scriptDraftContentHash(currentMarkdown!) == baseline.sourceHash;
    if (!targetStillCurrent) {
      _showCanvasSnack('正文已变化，请重新发问后再生成修改');
      return;
    }
    final target = _CanvasAiRichTarget(
      range: baseline.range,
      markdown: baseline.sourceMarkdown,
      documentJson: _documentSignature,
      editScope: baseline.editScope,
    );
    if (target.markdown.trim().isEmpty) {
      _showCanvasSnack('当前范围没有可处理的正文');
      return;
    }
    _activeAiTarget = target;
    final controller = _canvasAiController;
    String? unifiedDiff;
    try {
      unifiedDiff = canvasExtractUnifiedDiff(normalizedSuggestion);
    } on CanvasUnifiedDiffException {
      _showCanvasSnack('检测到多个修改版本，请让 AI 只返回一个差分');
      return;
    }
    final generating = controller.generateChatRewrite(
      instruction: unifiedDiff == null ? normalizedSuggestion : '应用创作对话返回的差分建议',
      unifiedDiff: unifiedDiff,
      documentMarkdown: target.markdown,
      documentRevision: baseline.documentRevision,
      editScope: target.editScope,
      selectionStart: target.editScope == CanvasAiEditScope.local ? 0 : null,
      selectionEnd: target.editScope == CanvasAiEditScope.local
          ? target.markdown.length
          : null,
    );
    _recordAiTarget(controller.request, target);
    final generated = await generating;
    if (!mounted) return;
    if (generated ||
        controller.status == CanvasAiTransformStatus.failed ||
        controller.status == CanvasAiTransformStatus.awaitingCompletion) {
      await _showAiPreview();
    }
  }

  Future<void> _startNewDraft() async {
    if (_interactionLocked) {
      _showInteractionLocked();
      return;
    }
    if (_title.text.trim().isEmpty && _bodyIsEmpty) return;
    await _dismissEditorKeyboard();
    if (!mounted) return;
    final choice = await showV3ActionSheet<String>(
      context: context,
      title: '新建草稿',
      message: '当前未保存内容会被清除。',
      items: const [
        V3ActionSheetItem(
          value: 'new',
          icon: Icons.delete_sweep_outlined,
          label: '放弃当前内容并新建',
          destructive: true,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (!await _beginLeaveSettlement()) return;
    try {
      if (!await _settlePendingCanvasChatForDestructiveDiscard() || !mounted) {
        return;
      }
      final checkpoint = _captureLeaveCheckpoint();
      final cleared = await _clearPersistedDraftDeferred();
      if (!mounted) return;
      if (!cleared) {
        _showCanvasSnack('草稿清理失败，请稍后重试');
        return;
      }
      if (!await _validateLeaveCheckpoint(checkpoint)) return;
      if (_pendingSavedId == null) await _deleteOwnedCanvasImages();
      if (!mounted) return;
      _resetEditor();
    } finally {
      _releaseLeaveSettlement();
    }
  }

  void _resetEditor({bool resetAi = true}) {
    final aiController = resetAi ? _canvasAiController : null;
    _hydrating = true;
    _draftPersistenceSuppressed = false;
    _autosaveCoordinator.cancelCloudSync();
    _detachCanvasChatSession();
    _title.clear();
    _replaceBodyDocument(Document(), const TextSelection.collapsed(offset: 0));
    _body.document.history.clear();
    _linkedMaterials.clear();
    _linkedMaterialsByDocument.clear();
    _ownedCanvasImageIds.clear();
    _sourceTopicId = null;
    _sourceTitle = null;
    _pendingSavedId = null;
    _boundAssetFingerprint = null;
    _entryIdentity = const CanvasEntryIntent.blank().stableSourceId;
    _sessionId = _newCanvasSessionId();
    _scriptDraftReceipt = null;
    _initialGenerationEpoch++;
    _bootstrapErrorMessage = null;
    _selectedImageId = null;
    _frozenBodySelection = null;
    _linkEditorVisible = false;
    _linkEditingExisting = false;
    _linkLabel.clear();
    _linkUrl.clear();
    _linkError = null;
    _activeAiTarget = null;
    _profileActivityRecorded = false;
    _automaticInitialNoteCreation = false;
    _automaticInitialNoteCreationScheduled = false;
    _autosaveFailed = false;
    _savedDraftCleanupPending = false;
    _historyCommitReceipt = null;
    _unreadableSessionMetadata = false;
    _unreadableStructuredDraft = false;
    _allowLeave = false;
    _leaveGuardIdentity = Object();
    _documentRevision = 0;
    _draftCreatedAt = DateTime.now().toUtc();
    _lastDocumentSignature = _documentSignature;
    _rememberLinkedMaterialsForDocument();
    _activeEditorTarget = _CanvasEditorTarget.body;
    _toolbarPanel = _CanvasToolbarPanel.none;
    _aiEditScope = CanvasAiEditScope.global;
    _finishHydration(markClean: true);
    aiController?.reset();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bodyFocus.requestFocus();
    });
  }

  void _detachCanvasChatSession() {
    _canvasChatSubscription?.close();
    _canvasChatSubscription = null;
    _chatThreadId = null;
    _chatRewriteReceipts.clear();
    _pendingChatRewriteTurn = null;
    _canvasChatStarted = false;
    _canvasChatFreshResetPending = false;
  }

  void _restoreChatRewriteReceipts(
    Iterable<CreationCanvasChatRewriteReceipt> receipts,
  ) {
    _chatRewriteReceipts.clear();
    _pendingChatRewriteTurn = null;
    for (final receipt in receipts) {
      final assistantMessageId = receipt.assistantMessageId;
      if (assistantMessageId != null) {
        _chatRewriteReceipts[assistantMessageId] = receipt;
      } else if (receipt.submissionPhase ==
              CreationCanvasChatSubmissionPhase.prepared ||
          _canvasChatControllerOwns(receipt)) {
        _pendingChatRewriteTurn = _CanvasChatPendingRewriteTurn.fromReceipt(
          receipt,
        );
      }
    }
    _trimChatRewriteReceipts();
  }

  bool _canvasChatControllerOwns(CreationCanvasChatRewriteReceipt receipt) {
    final state = ref.read(creationCanvasChatControllerProvider).state;
    final receiptThreadId = _clean(receipt.threadId);
    if (receiptThreadId != null &&
        _clean(state.activeThreadId) != receiptThreadId) {
      return false;
    }
    final receiptRunId = _clean(receipt.agentRunId);
    if (receiptRunId != null) {
      return receiptThreadId != null &&
          _clean(state.turnState.agentRunId) == receiptRunId;
    }
    return state.turnState.userMessageId == receipt.userMessageId;
  }

  void _trimChatRewriteReceipts() {
    while (_chatRewriteReceipts.length >
        CreationCanvasDraft.maxChatRewriteReceipts) {
      _chatRewriteReceipts.remove(_chatRewriteReceipts.keys.first);
    }
  }

  List<CreationCanvasChatRewriteReceipt> _chatReceiptsForPersistence() {
    final receipts = <CreationCanvasChatRewriteReceipt>[
      ..._chatRewriteReceipts.values,
      if (_pendingChatRewriteTurn case final pending?) pending.toReceipt(),
    ];
    final overflow =
        receipts.length - CreationCanvasDraft.maxChatRewriteReceipts;
    return List<CreationCanvasChatRewriteReceipt>.unmodifiable(
      overflow <= 0 ? receipts : receipts.skip(overflow),
    );
  }

  Future<bool> _confirmDiscardForLeave(BuildContext guardContext) async {
    if (_leaveDecisionOpen) return false;
    _leaveDecisionOpen = true;
    try {
      return await _confirmDiscardForLeaveImpl(guardContext);
    } finally {
      _leaveDecisionOpen = false;
    }
  }

  Future<bool> _confirmDiscardForLeaveImpl(BuildContext guardContext) async {
    await _dismissEditorKeyboard();
    if (!mounted || !guardContext.mounted) return false;
    if (_linkEditorVisible &&
        !await _resolveLinkEditorBeforeLeave(guardContext)) {
      return false;
    }
    if (!mounted || !guardContext.mounted) return false;
    if (_interactionPolicy.aiNeedsResolution &&
        !await _resolveAiBeforeLeave(guardContext)) {
      return false;
    }
    if (!mounted || !guardContext.mounted) return false;
    if (_historyCommitReceipt != null) {
      final preserved = await _confirmPendingHistoryLeave(
        guardContext,
        retainLockOnSuccess: true,
      );
      if (!mounted || !preserved) return false;
      setState(() => _allowLeave = true);
      return true;
    }
    if (!_isDirty) {
      final settled = await _settleCleanRecoveryBeforeLeave(
        retainLockOnSuccess: true,
      );
      if (!mounted || !settled) return false;
      setState(() => _allowLeave = true);
      return true;
    }
    final editingBoundNote = _clean(_pendingSavedId) != null;
    final choice = await _chooseCanvasLeaveAction(
      guardContext,
      keepLabel: '保留草稿并退出',
      discardLabel: editingBoundNote ? '不保存并退出' : '放弃并退出',
      includeSaveToAssets: true,
      includeKeep: !editingBoundNote,
      message: editingBoundNote ? '保存会更新这篇笔记；不保存退出时，资产保持上一次保存的内容。' : null,
    );
    if (!mounted || choice == null || choice == 'continue') return false;
    if (choice == 'save') {
      await _confirmAndSave();
      return false;
    }
    if (!await _beginLeaveSettlement()) return false;
    var retainLock = false;
    try {
      if (choice == 'discard' &&
          (!await _abandonInitialDraftGenerationIfNeeded() || !mounted)) {
        return false;
      }
      if (choice == 'discard' &&
          !await _settlePendingCanvasChatForDestructiveDiscard()) {
        return false;
      }
      if (!mounted) return false;
      final checkpoint = _captureLeaveCheckpoint();
      final storageSettlement = await _settleDraftStorageForLeave(
        discard: choice == 'discard',
      );
      if (!mounted ||
          storageSettlement == _CanvasDraftStorageSettlement.cancelled) {
        return false;
      }
      if (storageSettlement == _CanvasDraftStorageSettlement.completed) {
        if (choice == 'keep') {
          await _deleteUnusedOwnedCanvasImages();
        } else if (_pendingSavedId == null) {
          await _deleteOwnedCanvasImages();
        }
        if (!mounted || !await _validateLeaveCheckpoint(checkpoint)) {
          return false;
        }
      } else {
        _draftPersistenceSuppressed = true;
      }
      setState(() => _allowLeave = true);
      retainLock = true;
      return true;
    } finally {
      if (!retainLock) _releaseLeaveSettlement();
    }
  }

  Future<bool> _pushCanvasOwnedRoute(String location) async {
    if (_interactionLocked) {
      _showInteractionLocked();
      return false;
    }
    var settlementHeld = false;
    if (_requiresLeaveSettlement) {
      if (!await _prepareCanvasForInternalNavigation()) return false;
      settlementHeld = _leaveSettlementInProgress;
    }
    if (!mounted) return false;
    if (!settlementHeld) _endCanvasVoiceBeforeNavigation();
    if (!mounted) return false;
    try {
      await context.push(location);
      return mounted;
    } finally {
      if (settlementHeld) _releaseLeaveSettlement();
    }
  }

  Future<({bool opened, T? result})> _pushCanvasOwnedRouteForResult<T>(
    String location,
  ) async {
    if (_interactionLocked) {
      _showInteractionLocked();
      return (opened: false, result: null);
    }
    var settlementHeld = false;
    if (_requiresLeaveSettlement) {
      if (!await _prepareCanvasForInternalNavigation()) {
        return (opened: false, result: null);
      }
      settlementHeld = _leaveSettlementInProgress;
    }
    if (!mounted) return (opened: false, result: null);
    if (!settlementHeld) _endCanvasVoiceBeforeNavigation();
    if (!mounted) return (opened: false, result: null);
    try {
      final result = await context.push<T>(location);
      return (opened: mounted, result: result);
    } finally {
      if (settlementHeld) _releaseLeaveSettlement();
    }
  }

  Future<bool> _prepareCanvasForInternalNavigation() async {
    await _dismissEditorKeyboard();
    if (!mounted) return false;
    if (!_isDirty) {
      return _settleCleanRecoveryBeforeLeave(retainLockOnSuccess: true);
    }
    final choice = await _chooseCanvasLeaveAction(
      context,
      keepLabel: '保留草稿并前往',
      discardLabel: '放弃草稿并前往',
    );
    if (!mounted || choice == null || choice == 'continue') return false;
    if (!await _beginLeaveSettlement()) return false;
    var retainLock = false;
    try {
      if (choice == 'discard' &&
          (!await _abandonInitialDraftGenerationIfNeeded() || !mounted)) {
        return false;
      }
      if (choice == 'discard' &&
          !await _settlePendingCanvasChatForDestructiveDiscard()) {
        return false;
      }
      if (!mounted) return false;
      final checkpoint = _captureLeaveCheckpoint();
      final storageSettlement = await _settleDraftStorageForLeave(
        discard: choice == 'discard',
      );
      if (!mounted ||
          storageSettlement == _CanvasDraftStorageSettlement.cancelled) {
        return false;
      }
      if (storageSettlement == _CanvasDraftStorageSettlement.completed) {
        if (choice == 'keep') {
          await _deleteUnusedOwnedCanvasImages();
        } else if (_pendingSavedId == null) {
          await _deleteOwnedCanvasImages();
        }
        if (!mounted || !await _validateLeaveCheckpoint(checkpoint)) {
          return false;
        }
        if (choice == 'discard') _resetEditor();
      }
      retainLock = true;
      return true;
    } finally {
      if (!retainLock) _releaseLeaveSettlement();
    }
  }

  Future<String?> _chooseCanvasLeaveAction(
    BuildContext sheetContext, {
    required String keepLabel,
    required String discardLabel,
    bool includeSaveToAssets = false,
    bool includeKeep = true,
    String? message,
  }) => showV3ActionSheet<String>(
    context: sheetContext,
    title: '离开自由创作？',
    message:
        message ??
        (includeSaveToAssets
            ? '可保存到资产，也可只保留本机草稿后退出。'
            : '可以保留草稿下次继续，或明确放弃当前内容。'),
    cancelLabel: '继续编辑',
    items: <V3ActionSheetItem<String>>[
      if (includeSaveToAssets && !_bodyIsEmpty)
        const V3ActionSheetItem(
          value: 'save',
          icon: Icons.cloud_upload_outlined,
          label: '保存到资产',
        ),
      if (includeKeep)
        V3ActionSheetItem(
          value: 'keep',
          icon: Icons.save_outlined,
          label: keepLabel,
        ),
      V3ActionSheetItem(
        value: 'discard',
        icon: Icons.delete_outline_rounded,
        label: discardLabel,
        destructive: true,
      ),
    ],
  );

  Future<bool> _resolveLinkEditorBeforeLeave(BuildContext sheetContext) async {
    final choice = await showV3ActionSheet<String>(
      context: sheetContext,
      title: '链接尚未应用',
      message: '先处理当前链接，再决定是否离开自由创作。',
      items: const <V3ActionSheetItem<String>>[
        V3ActionSheetItem(
          value: 'apply',
          icon: Icons.link_rounded,
          label: '应用链接',
        ),
        V3ActionSheetItem(
          value: 'discard',
          icon: Icons.link_off_rounded,
          label: '放弃链接修改',
          destructive: true,
        ),
        V3ActionSheetItem(
          value: 'continue',
          icon: Icons.edit_outlined,
          label: '继续编辑',
        ),
      ],
    );
    if (!mounted || choice == null || choice == 'continue') return false;
    if (choice == 'discard') {
      _closeLinkEditor();
      return true;
    }
    _applyLink();
    return !_linkEditorVisible;
  }

  Future<bool> _resolveAiBeforeLeave(BuildContext sheetContext) async {
    final status = _canvasAiController.status;
    final reviewing = status == CanvasAiTransformStatus.previewing;
    final choice = await showV3ActionSheet<String>(
      context: sheetContext,
      title: reviewing ? 'AI 建议尚未处理' : 'AI 仍在生成',
      message: reviewing
          ? '原文尚未改变。可以放弃本次建议后继续退出。'
          : '取消本次生成不会修改原文，当前正文仍会进入草稿结算。',
      items: <V3ActionSheetItem<String>>[
        V3ActionSheetItem(
          value: 'resolve',
          icon: reviewing ? Icons.close_rounded : Icons.stop_circle_outlined,
          label: reviewing ? '放弃建议并继续' : '取消生成并继续',
          destructive: true,
        ),
        const V3ActionSheetItem(
          value: 'continue',
          icon: Icons.edit_outlined,
          label: '返回创作',
        ),
      ],
    );
    if (!mounted || choice != 'resolve') return false;
    if (reviewing) {
      _rejectAiPreview();
    } else {
      _cancelAiProposal();
    }
    return true;
  }

  Future<_CanvasDraftStorageSettlement> _settleDraftStorageForLeave({
    required bool discard,
  }) async {
    while (mounted) {
      final succeeded = discard
          ? await _clearPersistedDraftDeferred()
          : await _persistDraftDeferred();
      if (!mounted) return _CanvasDraftStorageSettlement.cancelled;
      if (succeeded) return _CanvasDraftStorageSettlement.completed;

      final choice = await showV3ActionSheet<String>(
        context: context,
        title: discard ? '草稿记录无法删除' : '草稿无法写入本机',
        message: discard
            ? '退出后这条恢复记录可能仍会出现，但当前内容不会被覆盖。'
            : '可以重试、复制当前内容后退出，或明确承担未保存风险后退出。',
        items: <V3ActionSheetItem<String>>[
          const V3ActionSheetItem(
            value: 'retry',
            icon: Icons.refresh_rounded,
            label: '重试',
          ),
          if (!discard)
            const V3ActionSheetItem(
              value: 'copy',
              icon: Icons.copy_all_outlined,
              label: '复制内容后退出',
            ),
          V3ActionSheetItem(
            value: 'leave',
            icon: discard
                ? Icons.history_toggle_off_rounded
                : Icons.warning_amber_rounded,
            label: discard ? '保留恢复记录并退出' : '仍然退出（未保存）',
            destructive: true,
          ),
          const V3ActionSheetItem(
            value: 'continue',
            icon: Icons.edit_outlined,
            label: '继续编辑',
          ),
        ],
      );
      if (!mounted || choice == null || choice == 'continue') {
        return _CanvasDraftStorageSettlement.cancelled;
      }
      if (choice == 'retry') continue;
      if (choice == 'copy' && !await _copyCanvasContentForRecovery()) {
        continue;
      }
      _draftPersistenceSuppressed = true;
      return _CanvasDraftStorageSettlement.forcedExit;
    }
    return _CanvasDraftStorageSettlement.cancelled;
  }

  Future<bool> _copyCanvasContentForRecovery() async {
    try {
      final title = _title.text.trim();
      final markdown = _bodyMarkdown.trim();
      final content = [
        if (title.isNotEmpty) '# $title',
        if (markdown.isNotEmpty) markdown,
      ].join('\n\n');
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) _showCanvasSnack('当前内容已复制');
      return true;
    } on Object {
      if (mounted) _showCanvasSnack('复制失败，请继续编辑并手动备份内容');
      return false;
    }
  }

  Future<bool> _confirmForegroundIngress(BuildContext guardContext) async {
    await _dismissEditorKeyboard();
    if (!mounted || !guardContext.mounted) return false;
    if (_linkEditorVisible &&
        !await _resolveLinkEditorBeforeLeave(guardContext)) {
      return false;
    }
    if (!mounted || !guardContext.mounted) return false;
    if (_interactionPolicy.aiNeedsResolution &&
        !await _resolveAiBeforeLeave(guardContext)) {
      return false;
    }
    if (!mounted || !guardContext.mounted) return false;
    if (_historyCommitReceipt != null) {
      return _confirmPendingHistoryLeave(guardContext);
    }
    if (!_isDirty) return _settleCleanRecoveryBeforeLeave();
    final preserve = await _showCanvasConfirmationSheet(
      sheetContext: guardContext,
      title: '保留当前草稿？',
      message: '查看新内容前会先保存当前草稿，稍后可以继续编辑。',
      cancelLabel: '继续编辑',
      primaryLabel: '保留草稿并查看',
    );
    if (!mounted || !preserve) return false;
    if (!await _beginLeaveSettlement()) return false;
    try {
      final checkpoint = _captureLeaveCheckpoint();
      final storageSettlement = await _settleDraftStorageForLeave(
        discard: false,
      );
      if (!mounted ||
          storageSettlement == _CanvasDraftStorageSettlement.cancelled) {
        return false;
      }
      if (storageSettlement == _CanvasDraftStorageSettlement.forcedExit) {
        return true;
      }
      await _deleteUnusedOwnedCanvasImages();
      return mounted && await _validateLeaveCheckpoint(checkpoint);
    } finally {
      _releaseLeaveSettlement();
    }
  }

  Future<bool> _settleCleanRecoveryBeforeLeave({
    bool retainLockOnSuccess = false,
  }) async {
    if (!await _beginLeaveSettlement()) return false;
    var retainLock = false;
    try {
      final checkpoint = _captureLeaveCheckpoint();
      final storageSettlement = await _settleDraftStorageForLeave(
        discard: false,
      );
      if (!mounted ||
          storageSettlement == _CanvasDraftStorageSettlement.cancelled) {
        return false;
      }
      if (storageSettlement == _CanvasDraftStorageSettlement.completed &&
          !await _validateLeaveCheckpoint(checkpoint)) {
        return false;
      }
      retainLock = retainLockOnSuccess;
      return true;
    } finally {
      if (!retainLock) _releaseLeaveSettlement();
    }
  }

  Future<bool> _confirmPendingHistoryLeave(
    BuildContext guardContext, {
    bool retainLockOnSuccess = false,
  }) async {
    final preserve = await _showCanvasConfirmationSheet(
      sheetContext: guardContext,
      title: '保存尚未提交完成',
      message: switch (_historyCommitReceipt!.phase) {
        CreationCanvasHistoryCommitPhase.prepared =>
          '保存事务已安全准备，可以保留状态稍后继续；不能把它当作普通草稿放弃。',
        CreationCanvasHistoryCommitPhase.noteCommitted =>
          '笔记正文已经落盘，创作历史仍待提交。可以保留此状态稍后继续，不能把它当作普通草稿放弃。',
        CreationCanvasHistoryCommitPhase.historyCommitted =>
          '笔记与创作历史已经落盘，可以保留状态稍后完成同步与本地清理。',
      },
      cancelLabel: '继续提交',
      primaryLabel: '保留状态并离开',
    );
    if (!mounted || !preserve) return false;
    if (!await _beginLeaveSettlement()) return false;
    var retainLock = false;
    try {
      final checkpoint = _captureLeaveCheckpoint();
      final storageSettlement = await _settleDraftStorageForLeave(
        discard: false,
      );
      if (!mounted ||
          storageSettlement == _CanvasDraftStorageSettlement.cancelled) {
        return false;
      }
      if (storageSettlement == _CanvasDraftStorageSettlement.completed &&
          !await _validateLeaveCheckpoint(checkpoint)) {
        return false;
      }
      retainLock = retainLockOnSuccess;
      return true;
    } finally {
      if (!retainLock) _releaseLeaveSettlement();
    }
  }

  Future<bool> _beginLeaveSettlement() async {
    if (_leaveSettlementInProgress) return false;
    setState(() => _leaveSettlementInProgress = true);
    await _dismissEditorKeyboard();
    if (!mounted) return false;
    _endCanvasVoiceBeforeNavigation();
    await _autosaveCoordinator.cancelPersistAndDrain();
    await _draftPersistence.drain();
    return mounted;
  }

  void _releaseLeaveSettlement() {
    if (!mounted || !_leaveSettlementInProgress) return;
    setState(() => _leaveSettlementInProgress = false);
  }

  ({int epoch, String signature}) _captureLeaveCheckpoint() {
    _synchronizeDocumentState(scheduleAutosave: false);
    return (epoch: _draftStateEpoch, signature: _editorSignature);
  }

  Future<bool> _validateLeaveCheckpoint(
    ({int epoch, String signature}) checkpoint,
  ) async {
    _synchronizeDocumentState(scheduleAutosave: false);
    if (_draftStateEpoch == checkpoint.epoch &&
        _editorSignature == checkpoint.signature) {
      return true;
    }
    _draftPersistenceSuppressed = false;
    final recovered = await _persistDraftDeferred(notify: false);
    if (!mounted) return false;
    _showCanvasSnack(
      recovered ? '内容在离开过程中发生变化，最新草稿已保留，请重试' : '内容在离开过程中发生变化，草稿尚未保存，请重试',
    );
    return false;
  }

  Future<bool> _abandonInitialDraftGenerationIfNeeded() async {
    final restoredReceipt = _scriptDraftReceipt;
    if (_scriptDraftController.receipt == null && restoredReceipt != null) {
      final cancelled = await _scriptDraftController.cancelPersistedReceipt(
        restoredReceipt,
      );
      if (!mounted) return false;
      if (!cancelled) {
        _showCanvasSnack('生成会话暂时无法取消，请重试');
        return false;
      }
    }
    if (!_scriptDraftController.canAbandon) return true;
    await _scriptDraftController.cancel();
    if (!mounted) return false;
    if (_scriptDraftController.phase == ScriptDraftGenerationPhase.cancelled) {
      return true;
    }
    _showCanvasSnack('生成会话暂时无法取消，请重试');
    return false;
  }

  Future<void> _dismissEditorKeyboard() async {
    final keyboardWasVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!keyboardWasVisible) return;
    await Future<void>.delayed(V3InteractionTimingTokens.keyboardDismissal);
  }

  Future<void> _awaitSheetDismissal() async {
    await Future<void>.delayed(_canvasSheetDismissalDelay);
  }

  Future<bool> _showCanvasConfirmationSheet({
    required BuildContext sheetContext,
    required String title,
    required String message,
    required String cancelLabel,
    required String primaryLabel,
  }) async {
    final result = await showV3GlassBottomSheet<bool>(
      context: sheetContext,
      builder: (modalContext) => V3SheetScaffold(
        title: title,
        message: message,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(modalContext).pop(false),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(modalContext).pop(true),
                child: Text(primaryLabel),
              ),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  String get _interactionLockedMessage => _saving
      ? '正在保存，请稍候'
      : _leaveSettlementInProgress
      ? '正在确认草稿状态，请稍候'
      : _entryIntentTransitionInProgress
      ? '正在切换创作内容，请稍候'
      : _isInitialDraftBusy
      ? '正在准备初稿，请先返回或等待完成'
      : _unreadableSessionMetadata
      ? '草稿状态无法安全读取，请先返回或明确放弃恢复记录'
      : _historyCommitReceipt != null
      ? '笔记提交尚未完成，请先继续提交或保留状态退出'
      : _linkEditorVisible
      ? '请先应用或取消当前链接'
      : _interactionPolicy.isVoiceEngaged
      ? '请先结束当前语音输入'
      : _canvasAiController.status == CanvasAiTransformStatus.applying
      ? '正在应用 AI 修改，请稍候'
      : _interactionPolicy.aiNeedsResolution
      ? '请先应用、放弃或取消当前 AI 建议'
      : _interactionPolicy.isInitializing
      ? '正在恢复草稿，请稍候'
      : '当前操作暂不可用';

  void _showInteractionLocked() => _showCanvasSnack(_interactionLockedMessage);

  void _recordCanvasState(
    String phase, {
    bool failed = false,
    Map<String, Object?> metadata = const {},
  }) {
    try {
      _canvasLogger?.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.workAi,
          severity: failed ? DiagnosticSeverity.error : DiagnosticSeverity.info,
          safeSummary: 'Canvas state transition',
          correlationId: _sessionId,
          metadata: {
            'phase': phase,
            'creation_session_id': _sessionId,
            'document_revision': _documentRevision,
            'draft_epoch': _draftStateEpoch,
            'save_phase': _historyCommitReceipt?.phase.name,
            'note_id': _pendingSavedId,
            'local_write_failed': _autosaveFailed,
            ...metadata,
          },
        ),
      );
    } on Object {
      return;
    }
  }

  bool _ensureBodyEditor() {
    if (_activeEditorTarget != _CanvasEditorTarget.body ||
        _titleFocus.hasFocus) {
      _showCanvasSnack('请先定位到正文');
      return false;
    }
    return true;
  }

  VoidCallback? _bodyCommand(VoidCallback command) {
    if (!_bodyCommandsAvailable) return null;
    return command;
  }

  VoidCallback? _bodyCommandAsync(Future<void> Function() command) {
    if (!_bodyCommandsAvailable) return null;
    return () => unawaited(command());
  }

  void _undo() {
    if (_inlineAiReview != null) return;
    if (_activeEditorTarget == _CanvasEditorTarget.title) {
      _titleUndo.undo();
      return;
    }
    if (!_body.hasUndo) return;
    _clearSelectedImage();
    _body.undo();
  }

  void _redo() {
    if (_inlineAiReview != null) return;
    if (_activeEditorTarget == _CanvasEditorTarget.title) {
      _titleUndo.redo();
      return;
    }
    if (!_body.hasRedo) return;
    _clearSelectedImage();
    _body.redo();
  }

  void _setHeadingLevel(_CanvasHeadingLevel level) {
    final attribute = switch (level) {
      _CanvasHeadingLevel.h1 => Attribute.h1,
      _CanvasHeadingLevel.h2 => Attribute.h2,
      _CanvasHeadingLevel.h3 => Attribute.h3,
      _CanvasHeadingLevel.paragraph => Attribute.header,
    };
    _formatExclusiveBlock(
      level == _CanvasHeadingLevel.paragraph ? null : attribute,
    );
  }

  void _setAlignment(_CanvasTextAlignment alignment) {
    _applyAttribute(switch (alignment) {
      _CanvasTextAlignment.left => Attribute.leftAlignment,
      _CanvasTextAlignment.center => Attribute.centerAlignment,
      _CanvasTextAlignment.right => Attribute.rightAlignment,
    });
  }

  bool _hasSelectionAttribute(String key) =>
      _body.getSelectionStyle().attributes.containsKey(key);

  bool _selectionHasAttributeValue(Attribute<dynamic> attribute) =>
      _body.getSelectionStyle().attributes[attribute.key]?.value ==
      attribute.value;

  bool get _selectionIsTaskList =>
      _selectionHasAttributeValue(Attribute.checked) ||
      _selectionHasAttributeValue(Attribute.unchecked);

  bool get _selectionIsParagraph {
    final attributes = _body.getSelectionStyle().attributes;
    return !attributes.containsKey(Attribute.header.key) &&
        !attributes.containsKey(Attribute.list.key) &&
        !attributes.containsKey(Attribute.codeBlock.key) &&
        !attributes.containsKey(Attribute.blockQuote.key);
  }

  _CanvasTextAlignment get _selectionAlignment {
    final value = _body
        .getSelectionStyle()
        .attributes[Attribute.leftAlignment.key]
        ?.value;
    if (value == Attribute.centerAlignment.value) {
      return _CanvasTextAlignment.center;
    }
    if (value == Attribute.rightAlignment.value) {
      return _CanvasTextAlignment.right;
    }
    return _CanvasTextAlignment.left;
  }

  IconData _currentAlignmentIcon() => switch (_selectionAlignment) {
    _CanvasTextAlignment.left => Icons.format_align_left_rounded,
    _CanvasTextAlignment.center => Icons.format_align_center_rounded,
    _CanvasTextAlignment.right => Icons.format_align_right_rounded,
  };

  void _toggleAttribute(Attribute<dynamic> attribute) {
    final current = _body.getSelectionStyle().attributes[attribute.key];
    _applyAttribute(
      current?.value == attribute.value
          ? Attribute.clone(attribute, null)
          : attribute,
    );
  }

  void _toggleBlockAttribute(Attribute<dynamic> attribute) {
    _restoreFrozenBodySelection();
    final current = _body.getSelectionStyle().attributes[attribute.key];
    _formatExclusiveBlock(current?.value == attribute.value ? null : attribute);
  }

  void _formatExclusiveBlock(Attribute<dynamic>? selected) {
    _restoreFrozenBodySelection();
    _runSeparateEdit(() {
      for (final attribute in <Attribute<dynamic>>[
        Attribute.header,
        Attribute.list,
        Attribute.codeBlock,
        Attribute.blockQuote,
      ]) {
        _body.formatSelection(Attribute.clone(attribute, null));
      }
      if (selected != null) _body.formatSelection(selected);
    });
    _freezeBodySelection();
  }

  void _applyAttribute(Attribute<dynamic> attribute) {
    final panelOwnsSelection =
        _toolbarPanel != _CanvasToolbarPanel.none || _linkEditorVisible;
    if (panelOwnsSelection) {
      _restoreFrozenBodySelection();
    } else {
      _frozenBodySelection = null;
    }
    _runSeparateEdit(() => _body.formatSelection(attribute));
    if (panelOwnsSelection) _freezeBodySelection();
  }

  void _insertDivider() {
    _restoreFrozenBodySelection();
    final offset = _normalizedBodySelection().end;
    const insert = CanvasDocumentCodec.canvasDividerDeltaInsert;
    _insertEmbedAt(
      offset,
      Embeddable(insert.keys.single, insert.values.single),
    );
  }

  Future<void> _insertLink() async {
    if (!_interactionPolicy.canStartLinkEditing) {
      _showInteractionLocked();
      return;
    }
    _freezeBodySelection();
    final existing =
        _body.getSelectionStyle().attributes[Attribute.link.key]?.value
            as String?;
    if (existing?.trim().isNotEmpty == true) {
      final maxOffset = math.max(0, _body.document.length - 1);
      var queryOffset = _body.selection.extentOffset
          .clamp(0, maxOffset)
          .toInt();
      if (queryOffset == maxOffset && queryOffset > 0) queryOffset -= 1;
      final leaf = _body.document.querySegmentLeafNode(queryOffset).leaf;
      if (leaf != null &&
          leaf.style.attributes[Attribute.link.key]?.value == existing) {
        final range = getLinkRange(leaf);
        _frozenBodySelection = TextSelection(
          baseOffset: range.start,
          extentOffset: range.end,
        );
      }
    }
    final label = _selectedText();
    setState(() {
      _linkEditingExisting = existing?.trim().isNotEmpty == true;
      _linkLabel.text = label;
      _linkLabel.selection = TextSelection.collapsed(offset: label.length);
      _linkUrl.text = _linkEditingExisting ? existing!.trim() : 'https://';
      _linkUrl.selection = TextSelection.collapsed(
        offset: _linkUrl.text.length,
      );
      _linkError = null;
      _linkEditorVisible = true;
    });
  }

  void _applyLink() {
    final url = _linkUrl.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      setState(() => _linkError = '请输入有效的 http 或 https 链接');
      return;
    }
    _restoreFrozenBodySelection();
    var range = _normalizedBodySelection();
    final currentText = range.isCollapsed
        ? ''
        : _body.document.getPlainText(range.start, range.length);
    final enteredLabel = _linkLabel.text;
    final label = enteredLabel.trim().isEmpty ? url : enteredLabel;
    _runSeparateEdit(() {
      if (range.isCollapsed || currentText != label) {
        _body.replaceText(
          range.start,
          range.length,
          label,
          TextSelection.collapsed(offset: range.start + label.length),
        );
        range = _CanvasRichRange(
          start: range.start,
          end: range.start + label.length,
        );
      }
      _body.formatText(
        range.start,
        range.length,
        Attribute.fromKeyValue(Attribute.link.key, url),
      );
      _body.updateSelection(
        TextSelection.collapsed(offset: range.end),
        ChangeSource.local,
      );
    });
    _closeLinkEditor(restoreSelection: false);
  }

  void _removeLink() {
    _restoreFrozenBodySelection();
    final range = _normalizedBodySelection();
    _runSeparateEdit(() {
      _body.formatText(
        range.start,
        range.length,
        Attribute.clone(Attribute.link, null),
      );
      _body.updateSelection(
        TextSelection.collapsed(offset: range.end),
        ChangeSource.local,
      );
    });
    _closeLinkEditor(restoreSelection: false);
  }

  void _closeLinkEditor({bool restoreSelection = true}) {
    if (restoreSelection) _restoreFrozenBodySelection();
    _frozenBodySelection = null;
    setState(() {
      _linkEditorVisible = false;
      _linkEditingExisting = false;
      _linkError = null;
    });
    _bodyFocus.requestFocus();
  }

  String _selectedText() {
    final range = _normalizedBodySelection(useFrozen: true);
    if (range.isCollapsed) return '';
    final plainText = _body.document.toPlainText();
    return plainText.substring(range.start, range.end);
  }

  void _freezeBodySelection() {
    _frozenBodySelection = _body.selection;
  }

  void _restoreFrozenBodySelection() {
    final selection = _frozenBodySelection;
    if (selection == null) return;
    final maxOffset = math.max(0, _body.document.length - 1);
    _body.updateSelection(
      TextSelection(
        baseOffset: selection.baseOffset.clamp(0, maxOffset).toInt(),
        extentOffset: selection.extentOffset.clamp(0, maxOffset).toInt(),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
      ChangeSource.local,
    );
  }

  _CanvasRichRange _normalizedBodySelection({bool useFrozen = false}) {
    return _normalizeSelection(
      useFrozen && _frozenBodySelection != null
          ? _frozenBodySelection!
          : _body.selection,
    );
  }

  _CanvasRichRange _normalizeSelection(TextSelection selection) {
    final maxOffset = math.max(0, _body.document.length - 1);
    final base = selection.baseOffset.clamp(0, maxOffset).toInt();
    final extent = selection.extentOffset.clamp(0, maxOffset).toInt();
    return _CanvasRichRange(
      start: math.min(base, extent),
      end: math.max(base, extent),
    );
  }

  void _runSeparateEdit(VoidCallback edit) {
    _body.document.history.lastRecorded = 0;
    try {
      edit();
    } finally {
      _body.document.history.lastRecorded = 0;
    }
  }

  bool _commitAiCandidate(Delta rawCandidate, TextSelection rawSelection) {
    final beforeDocument = _body.document;
    final before = Delta.fromJson(beforeDocument.toDelta().toJson());
    final candidate = Delta.fromJson(rawCandidate.toJson());
    final beforeSelection = _body.selection;
    final beforeToggledStyle = _body.toggledStyle;
    final beforeLastDocumentSignature = _lastDocumentSignature;
    final history = beforeDocument.history;
    final undo = history.stack.undo
        .map((delta) => Delta.fromJson(delta.toJson()))
        .toList(growable: false);
    final redo = history.stack.redo
        .map((delta) => Delta.fromJson(delta.toJson()))
        .toList(growable: false);
    final lastOffset = math.max(0, _deltaContentLength(candidate) - 1);
    final selection = TextSelection(
      baseOffset: rawSelection.baseOffset.clamp(0, lastOffset).toInt(),
      extentOffset: rawSelection.extentOffset.clamp(0, lastOffset).toInt(),
      affinity: rawSelection.affinity,
      isDirectional: rawSelection.isDirectional,
    );
    final candidateDocument = Document.fromDelta(
      Delta.fromJson(candidate.toJson()),
    );
    final inverse = candidate.diff(before, cleanupSemantic: false);
    final candidateUndo = <Delta>[
      ...undo,
      if (inverse.isNotEmpty) Delta.fromJson(inverse.toJson()),
    ];
    while (candidateUndo.length > candidateDocument.history.maxStack) {
      candidateUndo.removeAt(0);
    }
    _restoreCanvasHistory(
      candidateDocument,
      undo: candidateUndo,
      redo: inverse.isEmpty ? redo : const <Delta>[],
      lastRecorded: 0,
    );

    try {
      _body.toggledStyle = const Style();
      _replaceBodyDocument(candidateDocument, selection);
      if (_body.document.toDelta() != candidate) {
        throw StateError('Canvas AI candidate commit mismatch');
      }
      _lastDocumentSignature = beforeLastDocumentSignature;
      return true;
    } on Object {
      final selectionChanged = _body.onSelectionChanged;
      _body.onSelectionChanged = null;
      try {
        _replaceBodyDocument(beforeDocument, beforeSelection);
        if (_body.document.toDelta() != before) {
          throw StateError('Canvas AI candidate rollback mismatch');
        }
      } on Object {
        final restored = Document.fromDelta(Delta.fromJson(before.toJson()));
        _restoreCanvasHistory(
          restored,
          undo: undo,
          redo: redo,
          lastRecorded: history.lastRecorded,
        );
        _replaceBodyDocument(restored, beforeSelection);
      } finally {
        _body.onSelectionChanged = selectionChanged;
        _body.toggledStyle = beforeToggledStyle;
        _lastDocumentSignature = beforeLastDocumentSignature;
      }
      return false;
    }
  }

  void _restoreCanvasHistory(
    Document document, {
    required List<Delta> undo,
    required List<Delta> redo,
    required int lastRecorded,
  }) {
    final history = document.history;
    history.stack.undo
      ..clear()
      ..addAll(undo.map((delta) => Delta.fromJson(delta.toJson())));
    history.stack.redo
      ..clear()
      ..addAll(redo.map((delta) => Delta.fromJson(delta.toJson())));
    history
      ..ignoreChange = false
      ..lastRecorded = lastRecorded;
  }

  Delta _insertionDelta(
    String markdown, {
    bool preserveTrailingParagraph = false,
  }) {
    final delta = _documentCodec.markdownToDelta(markdown);
    final length = _deltaContentLength(delta);
    if (preserveTrailingParagraph) return delta;
    return length <= 1 ? Delta() : delta.slice(0, length - 1);
  }

  Delta _candidateForAiTarget(_CanvasRichRange range, String markdown) {
    final edit = _aiTargetEdit(range, markdown);
    final candidate = QuillController(
      document: Document.fromDelta(_body.document.toDelta()),
      selection: _body.selection,
    );
    try {
      candidate.replaceText(
        range.start,
        edit.replacedLength,
        edit.replacement,
        null,
      );
      return candidate.document.toDelta();
    } finally {
      candidate.dispose();
    }
  }

  ({int replacedLength, Delta replacement}) _aiTargetEdit(
    _CanvasRichRange range,
    String markdown,
  ) {
    final plainText = _body.document.toPlainText();
    final consumesParagraphDelimiter =
        range.length > 0 &&
        range.end <= plainText.length &&
        plainText[range.end - 1] == '\n';
    final includesCompleteFinalLine = _rangeEndsWithCompleteLine(
      range,
      plainText,
    );
    final replacedLength = range.length + (includesCompleteFinalLine ? 1 : 0);
    final replacement = _insertionDelta(
      markdown,
      preserveTrailingParagraph:
          consumesParagraphDelimiter || includesCompleteFinalLine,
    );
    return (replacedLength: replacedLength, replacement: replacement);
  }

  void _insertMarkdownAt(
    int rawOffset,
    String markdown, {
    bool surroundWithParagraphs = false,
    bool requestFocus = true,
  }) {
    final plain = _body.document.toPlainText();
    final offset = rawOffset.clamp(0, math.max(0, plain.length - 1)).toInt();
    var insertion = _insertionDelta(markdown);
    if (surroundWithParagraphs) {
      final leading = offset == 0 || plain[offset - 1] == '\n' ? '' : '\n\n';
      final trailing = offset >= plain.length - 1 || plain[offset] == '\n'
          ? '\n'
          : '\n\n';
      insertion = (Delta()..insert(leading))
          .concat(insertion)
          .concat(Delta()..insert(trailing));
    }
    final insertionLength = _deltaContentLength(insertion);
    _runSeparateEdit(() {
      _body.replaceText(
        offset,
        0,
        insertion,
        TextSelection.collapsed(offset: offset + insertionLength),
        ignoreFocus: !requestFocus,
      );
    });
    if (requestFocus) _bodyFocus.requestFocus();
  }

  void _insertEmbedAt(
    int rawOffset,
    Embeddable embed, {
    bool requestFocus = true,
  }) {
    final plain = _body.document.toPlainText();
    final offset = rawOffset.clamp(0, math.max(0, plain.length - 1)).toInt();
    var insertion = Delta();
    if (offset > 0 && plain[offset - 1] != '\n') insertion.insert('\n');
    insertion
      ..insert(embed.toJson())
      ..insert('\n');
    final insertionLength = _deltaContentLength(insertion);
    _runSeparateEdit(() {
      _body.replaceText(
        offset,
        0,
        insertion,
        TextSelection.collapsed(offset: offset + insertionLength),
        ignoreFocus: !requestFocus,
      );
    });
    if (requestFocus) _bodyFocus.requestFocus();
  }

  void _recordAiTarget(CanvasAiRequest? request, _CanvasAiRichTarget target) {
    if (request == null ||
        request.targetHash != canvasTextHash(target.markdown)) {
      return;
    }
    final selection = _normalizedBodySelection(useFrozen: true);
    try {
      ref
          .read(diagnosticLoggerProvider)
          .log(
            DiagnosticLogInput(
              category: DiagnosticCategory.workAi,
              severity: DiagnosticSeverity.info,
              safeSummary: 'Canvas AI editor target frozen',
              correlationId: request.requestId,
              metadata: {
                'phase': 'editor_target_frozen',
                'operation_id': request.requestId,
                'creation_session_id': _sessionId,
                'action': request.action?.name ?? 'rewrite',
                'scope': target.editScope.name,
                'editor_selection_start': selection.start,
                'editor_selection_end': selection.end,
                'editor_target_start': target.range.start,
                'editor_target_end': target.range.end,
                'target_hash': request.targetHash,
                'document_revision': request.documentRevision,
              },
            ),
          );
    } on Object {
      return;
    }
  }

  _CanvasAiRichTarget? _createAiTarget(CanvasAiEditScope editScope) {
    final selection = _normalizedBodySelection(useFrozen: true);
    if (editScope == CanvasAiEditScope.local && selection.isCollapsed) {
      return null;
    }
    final range = editScope == CanvasAiEditScope.local
        ? selection
        : _CanvasRichRange(
            start: 0,
            end: math.max(0, _body.document.length - 1),
          );
    if (range.isCollapsed) return null;
    return _CanvasAiRichTarget(
      range: range,
      markdown: _markdownForRange(range),
      documentJson: _documentSignature,
      editScope: editScope,
    );
  }

  bool _rangeEndsWithCompleteLine(_CanvasRichRange range, String plainText) =>
      range.length > 0 &&
      range.end < plainText.length &&
      plainText[range.end] == '\n' &&
      ((range.start == 0 && range.end == plainText.length - 1) ||
          (plainText[range.end - 1] != '\n' &&
              range.start <= plainText.lastIndexOf('\n', range.end - 1) + 1));

  String _markdownForRange(_CanvasRichRange range) {
    final document = _body.document.toDelta();
    var delta = document.slice(range.start, range.end);
    if (_rangeEndsWithCompleteLine(range, _body.document.toPlainText())) {
      delta = delta.concat(document.slice(range.end, range.end + 1));
    } else if (delta.isEmpty ||
        delta.last.data is! String ||
        !(delta.last.data as String).endsWith('\n')) {
      delta = delta.concat(Delta()..insert('\n'));
    }
    return _documentCodec.deltaToMarkdown(delta);
  }

  Future<void> _openKnowledgeNotePicker() async {
    _freezeBodySelection();
    final insertionOffset = _normalizedBodySelection(useFrozen: true).end;
    await _dismissEditorKeyboard();
    if (!mounted || _interactionLocked) return;
    final library = ref.read(knowledgeLibraryControllerProvider);
    final result = await showV3KnowledgeNotePicker(
      context: context,
      notes: library.notes.where((note) => note.id != _pendingSavedId),
      title: '导入笔记',
      searchHint: '搜索要导入的笔记',
    );
    if (!mounted || result == null || result.selectedNotes.isEmpty) return;
    final blocks = <String>[];
    final addedReferences = <V3LinkedMaterialRef>[];
    var skipped = 0;
    for (final note in result.selectedNotes) {
      final rawBody = note.rawBody.trim();
      if (rawBody.isEmpty) {
        skipped += 1;
        continue;
      }
      final title = note.title.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      blocks.add('## $title\n\n$rawBody');
      addedReferences.add(
        V3LinkedMaterialRef(
          id: note.id,
          source: note.source,
          title: note.title,
          summary: note.summaryBody,
        ),
      );
    }
    if (blocks.isEmpty) {
      _showCanvasSnack('所选笔记没有可导入的原始正文');
      return;
    }
    _rememberLinkedMaterialsForDocument();
    try {
      _insertMarkdownAt(
        insertionOffset,
        _sanitizeCanvasImportMarkdown(blocks.join('\n\n')),
        surroundWithParagraphs: true,
      );
    } on FormatException {
      _showCanvasSnack('所选笔记包含暂不支持的格式，未执行导入');
      return;
    }
    final mergedReferences = _uniqueLinkedMaterials(<V3LinkedMaterialRef>[
      ..._linkedMaterials,
      ...addedReferences,
    ]);
    _linkedMaterials
      ..clear()
      ..addAll(mergedReferences);
    _rememberLinkedMaterialsForDocument();
    _autosaveCoordinator.schedule();
    _showCanvasSnack(
      skipped == 0
          ? '已导入 ${blocks.length} 条笔记'
          : '已导入 ${blocks.length} 条笔记，$skipped 条无原始正文未导入',
    );
  }

  void _rememberLinkedMaterialsForDocument() {
    _linkedMaterialsByDocument[_documentSignature] =
        List<V3LinkedMaterialRef>.unmodifiable(_linkedMaterials);
  }

  void _selectImage(String resourceId, int offset) {
    if (!mounted) return;
    setState(() => _selectedImageId = resourceId);
    if (offset >= 0) {
      _body.updateSelection(
        TextSelection.collapsed(offset: offset + 1),
        ChangeSource.local,
      );
    }
  }

  void _clearSelectedImage() {
    if (_selectedImageId == null || !mounted) return;
    setState(() => _selectedImageId = null);
  }

  Set<String> _canvasImageIdsInDocument() {
    final ids = <String>{};
    for (final operation in _body.document.toDelta().operations) {
      final data = operation.data;
      if (data is! Map ||
          !data.containsKey(CanvasImageEmbedData.deltaEmbedType)) {
        continue;
      }
      try {
        ids.add(CanvasImageEmbedData.fromDeltaInsert(data).resourceId);
      } on FormatException {
        // Invalid embeds are never treated as owned resources.
      }
    }
    return ids;
  }

  bool _isImageReferencedByKnowledge(String resourceId) {
    final marker = 'app-private-canvas-image://$resourceId';
    return ref
        .read(knowledgeLibraryControllerProvider)
        .notes
        .any((note) => note.rawBody.contains(marker));
  }

  Future<void> _deleteOwnedCanvasImages() async {
    for (final resourceId in _ownedCanvasImageIds.toList(growable: false)) {
      if (_isImageReferencedByKnowledge(resourceId)) continue;
      if (await _deleteCanvasImageFile(resourceId)) {
        _ownedCanvasImageIds.remove(resourceId);
      }
    }
  }

  Future<void> _deleteUnusedOwnedCanvasImages() async {
    final retained = _canvasImageIdsInDocument();
    for (final resourceId in _ownedCanvasImageIds.toList(growable: false)) {
      if (retained.contains(resourceId) ||
          _isImageReferencedByKnowledge(resourceId)) {
        continue;
      }
      if (await _deleteCanvasImageFile(resourceId)) {
        _ownedCanvasImageIds.remove(resourceId);
      }
    }
  }

  void _resizeImage(int offset, CanvasImageEmbedData data) {
    _rememberLinkedMaterialsForDocument();
    _runSeparateEdit(() {
      _body.replaceText(
        offset,
        1,
        Embeddable(CanvasImageEmbedData.deltaEmbedType, data.toJson()),
        TextSelection.collapsed(offset: offset + 1),
        ignoreFocus: true,
      );
    });
    _rememberLinkedMaterialsForDocument();
  }
}

String _canvasEditorSnapshotSignature({
  required String title,
  required String documentSignature,
  required String? sourceTopicId,
  required String? sourceTitle,
  required Iterable<V3LinkedMaterialRef> linkedMaterials,
}) => [
  title,
  documentSignature,
  sourceTopicId ?? '',
  sourceTitle ?? '',
  ...(linkedMaterials.toList()
        ..sort((left, right) => left.id.compareTo(right.id)))
      .map((material) => material.id),
].join('\u0000');

@immutable
class _CanvasSaveAttempt {
  const _CanvasSaveAttempt({
    required this.rawTitle,
    required this.title,
    required this.markdown,
    required this.documentJson,
    required this.documentRevision,
    required this.documentSignature,
    required this.editorSignature,
    required this.sourceTopicId,
    required this.sourceTitle,
    required this.entryIdentity,
    required this.sessionId,
    required this.createdAt,
    required this.existingId,
    required this.expectedNote,
    required this.expectedFingerprint,
    required this.editorLinkedMaterials,
    required this.saveLinkedMaterials,
    required this.historyId,
  });

  final String rawTitle;
  final String title;
  final String markdown;
  final String documentJson;
  final int documentRevision;
  final String documentSignature;
  final String editorSignature;
  final String? sourceTopicId;
  final String? sourceTitle;
  final String? entryIdentity;
  final String sessionId;
  final DateTime createdAt;
  final String? existingId;
  final V3FeedItem? expectedNote;
  final String? expectedFingerprint;
  final List<V3LinkedMaterialRef> editorLinkedMaterials;
  final List<V3LinkedMaterialRef> saveLinkedMaterials;
  final String? historyId;

  String get committedEditorSignature => _canvasEditorSnapshotSignature(
    title: rawTitle,
    documentSignature: documentSignature,
    sourceTopicId: sourceTopicId,
    sourceTitle: sourceTitle,
    linkedMaterials: saveLinkedMaterials,
  );

  String historyIdFor(String noteId) => historyId ?? noteId;

  CreationCanvasSaveSnapshot get frozenSnapshot => CreationCanvasSaveSnapshot(
    rawTitle: rawTitle,
    title: title,
    markdown: markdown,
    documentJson: documentJson,
    documentRevision: documentRevision,
    sessionId: sessionId,
    createdAt: createdAt,
    sourceTopicId: sourceTopicId,
    sourceTitle: sourceTitle,
    entryIdentity: entryIdentity,
    linkedMaterials: saveLinkedMaterials,
  );

  String snapshotHashForBound(String noteId) =>
      frozenSnapshot.hashForBound(noteId);

  _CanvasSaveAttempt withFrozenSnapshot(CreationCanvasSaveSnapshot snapshot) {
    if (snapshot.sessionId != sessionId ||
        snapshot.entryIdentity != entryIdentity) {
      throw const FormatException(
        'Canvas save snapshot belongs to another session',
      );
    }
    final codec = CanvasDocumentCodec();
    final document = codec.documentFromDeltaJson(snapshot.documentJson);
    if (codec.documentToMarkdown(document).trim() != snapshot.markdown.trim()) {
      throw const FormatException(
        'Canvas save document does not match Markdown',
      );
    }
    return _CanvasSaveAttempt(
      rawTitle: snapshot.rawTitle,
      title: snapshot.title,
      markdown: snapshot.markdown,
      documentJson: snapshot.documentJson,
      documentRevision: snapshot.documentRevision,
      documentSignature: jsonEncode(document.toDelta().toJson()),
      editorSignature: editorSignature,
      sourceTopicId: snapshot.sourceTopicId,
      sourceTitle: snapshot.sourceTitle,
      entryIdentity: snapshot.entryIdentity,
      sessionId: snapshot.sessionId,
      createdAt: snapshot.createdAt,
      existingId: existingId,
      expectedNote: expectedNote,
      expectedFingerprint: expectedFingerprint,
      editorLinkedMaterials: editorLinkedMaterials,
      saveLinkedMaterials: snapshot.linkedMaterials,
      historyId: historyId,
    );
  }

  bool matchesPendingHistory(CreationCanvasHistoryCommitReceipt receipt) =>
      (receipt.phase == CreationCanvasHistoryCommitPhase.prepared
          ? existingId == receipt.baseNoteId &&
                expectedFingerprint == receipt.baseNoteFingerprint
          : existingId == receipt.noteId) &&
      historyIdFor(receipt.noteId) == receipt.historyId &&
      snapshotHashForBound(receipt.noteId) == receipt.editorSnapshotHash;
}

enum _CanvasMoreAction { history, newDraft }

enum _DraftConflictChoice { continueDraft, openCurrentEntry }

enum _CanvasDraftStorageSettlement { completed, forcedExit, cancelled }

enum _CanvasBootstrapPhase {
  resolving,
  awaitingDraftChoice,
  generating,
  ready,
  failed,
}

enum _CanvasEditorTarget { title, body }

enum _CanvasHeadingLevel { h1, h2, h3, paragraph }

enum _CanvasToolbarPanel { none, ai, text, block, alignment }

enum _CanvasTextAlignment { left, center, right }

@immutable
class _CanvasRichRange {
  const _CanvasRichRange({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
  bool get isCollapsed => start == end;
}

@immutable
class _CanvasAiRichTarget {
  const _CanvasAiRichTarget({
    required this.range,
    required this.markdown,
    required this.documentJson,
    required this.editScope,
  });

  final _CanvasRichRange range;
  final String markdown;
  final String documentJson;
  final CanvasAiEditScope editScope;
}

@immutable
class _CanvasAiToolChoice {
  const _CanvasAiToolChoice({required this.action, required this.editScope});

  final CanvasAiAction action;
  final CanvasAiEditScope editScope;
}

class _CanvasAiToolSheet extends StatefulWidget {
  const _CanvasAiToolSheet({
    required this.hasSelection,
    required this.initialScope,
  });

  final bool hasSelection;
  final CanvasAiEditScope initialScope;

  @override
  State<_CanvasAiToolSheet> createState() => _CanvasAiToolSheetState();
}

class _CanvasAiToolSheetState extends State<_CanvasAiToolSheet> {
  late CanvasAiEditScope _scope = widget.initialScope;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return V3SheetScaffold(
      title: 'AI 创作工具',
      message: widget.hasSelection ? '已选择正文' : '未选择正文',
      maxHeightFactor: .82,
      child: Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SegmentedButton<CanvasAiEditScope>(
                key: const ValueKey<String>('canvas-ai-scope-selector'),
                showSelectedIcon: false,
                segments: <ButtonSegment<CanvasAiEditScope>>[
                  const ButtonSegment<CanvasAiEditScope>(
                    value: CanvasAiEditScope.global,
                    icon: Icon(Icons.article_outlined),
                    label: Text('全文'),
                  ),
                  ButtonSegment<CanvasAiEditScope>(
                    value: CanvasAiEditScope.local,
                    icon: const Icon(Icons.select_all_rounded),
                    label: const Text('选中文字'),
                    enabled: widget.hasSelection,
                  ),
                ],
                selected: <CanvasAiEditScope>{_scope},
                onSelectionChanged: (value) {
                  if (value.isEmpty) return;
                  final next = value.first;
                  if (next == CanvasAiEditScope.local && !widget.hasSelection) {
                    return;
                  }
                  setState(() => _scope = next);
                },
              ),
            ),
            Expanded(
              child: ListView.separated(
                key: const ValueKey<String>('canvas-ai-action-list'),
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: CanvasAiAction.values.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: tokens.line),
                itemBuilder: (context, index) {
                  final action = CanvasAiAction.values[index];
                  return Semantics(
                    button: true,
                    label: action.label,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        key: ValueKey<String>(
                          'canvas-ai-action-${action.name}',
                        ),
                        onTap: () => Navigator.of(context).pop(
                          _CanvasAiToolChoice(
                            action: action,
                            editScope: _scope,
                          ),
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 58),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                SizedBox.square(
                                  dimension: 40,
                                  child: Icon(
                                    _actionIcon(action),
                                    color: tokens.primary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        action.label,
                                        style: HuahuoV3Theme.body.copyWith(
                                          color: tokens.ink,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _actionSubtitle(action),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: HuahuoV3Theme.meta.copyWith(
                                          color: tokens.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _CanvasChatRewriteTarget {
  const _CanvasChatRewriteTarget({
    required this.range,
    required this.sourceText,
    required this.contextText,
    required this.documentSignature,
    required this.documentRevision,
  });

  final _CanvasRichRange range;
  final String sourceText;
  final String contextText;
  final String documentSignature;
  final int documentRevision;
}

@immutable
class _CanvasChatRewriteBaseline {
  const _CanvasChatRewriteBaseline({
    required this.range,
    required this.sourceMarkdown,
    required this.sourceHash,
    required this.chatContext,
    required this.documentHash,
    required this.documentRevision,
    required this.editScope,
  });

  final _CanvasRichRange range;
  final String sourceMarkdown;
  final String sourceHash;
  final String chatContext;
  final String documentHash;
  final int documentRevision;
  final CanvasAiEditScope editScope;
}

class _CanvasChatPendingRewriteTurn {
  _CanvasChatPendingRewriteTurn({
    required this.baseline,
    required this.threadId,
    required this.userMessageId,
    required this.agentRunId,
    required this.requestText,
    String? createThreadIdempotencyKey,
    String? messageIdempotencyKey,
    this.submissionPhase = CreationCanvasChatSubmissionPhase.prepared,
  }) : createThreadIdempotencyKey =
           createThreadIdempotencyKey ??
           creationCanvasChatIdempotencyKey(
             operation: 'create-thread',
             userMessageId: userMessageId,
           ),
       messageIdempotencyKey =
           messageIdempotencyKey ??
           creationCanvasChatIdempotencyKey(
             operation: 'send-message',
             userMessageId: userMessageId,
           );

  final _CanvasChatRewriteBaseline baseline;
  final String? threadId;
  final String userMessageId;
  final String? agentRunId;
  final String? requestText;
  final String createThreadIdempotencyKey;
  final String messageIdempotencyKey;
  final CreationCanvasChatSubmissionPhase submissionPhase;

  factory _CanvasChatPendingRewriteTurn.fromReceipt(
    CreationCanvasChatRewriteReceipt receipt,
  ) => _CanvasChatPendingRewriteTurn(
    baseline: receipt.toBaseline(),
    threadId: receipt.threadId,
    userMessageId: receipt.userMessageId,
    agentRunId: receipt.agentRunId,
    requestText: receipt.requestText,
    createThreadIdempotencyKey: receipt.createThreadIdempotencyKey,
    messageIdempotencyKey: receipt.messageIdempotencyKey,
    submissionPhase: receipt.submissionPhase,
  );

  _CanvasChatPendingRewriteTurn bindTurn({
    required String threadId,
    String? agentRunId,
    String? userMessageId,
  }) => _CanvasChatPendingRewriteTurn(
    baseline: baseline,
    threadId: threadId,
    userMessageId: userMessageId ?? this.userMessageId,
    agentRunId: agentRunId ?? this.agentRunId,
    requestText: requestText,
    createThreadIdempotencyKey: createThreadIdempotencyKey,
    messageIdempotencyKey: messageIdempotencyKey,
    submissionPhase: submissionPhase,
  );

  _CanvasChatPendingRewriteTurn withSubmissionPhase(
    CreationCanvasChatSubmissionPhase phase,
  ) => _CanvasChatPendingRewriteTurn(
    baseline: baseline,
    threadId: threadId,
    userMessageId: userMessageId,
    agentRunId: agentRunId,
    requestText: requestText,
    createThreadIdempotencyKey: createThreadIdempotencyKey,
    messageIdempotencyKey: messageIdempotencyKey,
    submissionPhase: phase,
  );

  CreationCanvasChatRewriteReceipt toReceipt({String? assistantMessageId}) =>
      CreationCanvasChatRewriteReceipt(
        threadId: threadId,
        userMessageId: userMessageId,
        createThreadIdempotencyKey: createThreadIdempotencyKey,
        messageIdempotencyKey: messageIdempotencyKey,
        submissionPhase: submissionPhase,
        agentRunId: agentRunId,
        assistantMessageId: assistantMessageId,
        rangeStart: baseline.range.start,
        rangeEnd: baseline.range.end,
        sourceMarkdown: baseline.sourceMarkdown,
        sourceHash: baseline.sourceHash,
        documentHash: baseline.documentHash,
        documentRevision: baseline.documentRevision,
        selectionScoped: baseline.editScope == CanvasAiEditScope.local,
        requestText: requestText,
      );
}

extension on CreationCanvasChatRewriteReceipt {
  _CanvasChatRewriteBaseline toBaseline() => _CanvasChatRewriteBaseline(
    range: _CanvasRichRange(start: rangeStart, end: rangeEnd),
    sourceMarkdown: sourceMarkdown,
    sourceHash: sourceHash,
    chatContext: '',
    documentHash: documentHash,
    documentRevision: documentRevision,
    editScope: selectionScoped
        ? CanvasAiEditScope.local
        : CanvasAiEditScope.global,
  );
}

final _safeCanvasResourceId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');

Future<File?> _resolveCanvasPrivateImageById(String resourceId) async {
  if (!_safeCanvasResourceId.hasMatch(resourceId)) {
    return null;
  }
  final root = await getApplicationSupportDirectory();
  final file = File(
    '${root.path}${Platform.pathSeparator}HuahuoAI'
    '${Platform.pathSeparator}CanvasImages'
    '${Platform.pathSeparator}$resourceId',
  );
  return await file.exists() ? file : null;
}

Future<bool> _deleteCanvasImageFile(String resourceId) async {
  try {
    final file = await _resolveCanvasPrivateImageById(resourceId);
    if (file == null) return true;
    await file.delete();
    return true;
  } on Object {
    return false;
  }
}

List<V3LinkedMaterialRef> _uniqueLinkedMaterials(
  Iterable<V3LinkedMaterialRef> materials,
) {
  final values = <V3LinkedMaterialRef>[];
  final ids = <String>{};
  for (final material in materials) {
    if (ids.add(material.id)) values.add(material);
  }
  return values;
}

String _sanitizeCanvasImportMarkdown(String source) {
  return source.replaceAllMapped(
    RegExp(r'!\[([^\]\r\n]*)\]\((https?:\/\/[^)\s]+)\)'),
    (match) {
      final alt = (match.group(1) ?? '').trim();
      final url = match.group(2)!;
      return '${alt.isEmpty ? '图片' : alt}（$url）';
    },
  );
}

int _deltaContentLength(Delta delta) {
  return delta.operations.fold<int>(
    0,
    (length, operation) => length + (operation.length ?? 0),
  );
}

DefaultStyles _canvasEditorStyles(BuildContext context) {
  final tokens = HuahuoV3Theme.tokensOf(context);
  final color = tokens.text;
  const horizontal = HorizontalSpacing(0, 0);
  const lineSpacing = VerticalSpacing(0, 0);
  DefaultTextBlockStyle block(
    double size,
    FontWeight weight, {
    double top = 5,
    double bottom = 5,
    double height = 1.62,
  }) {
    return DefaultTextBlockStyle(
      TextStyle(
        color: color,
        fontSize: size,
        height: height,
        fontWeight: weight,
        fontFamily: HuahuoV3Theme.fontFamily,
        fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
      ),
      horizontal,
      VerticalSpacing(top, bottom),
      lineSpacing,
      null,
    );
  }

  return DefaultStyles(
    paragraph: block(16, FontWeight.w400, top: 3, bottom: 3, height: 1.55),
    h1: block(25, FontWeight.w700, top: 14, bottom: 6, height: 1.32),
    h2: block(21, FontWeight.w700, top: 12, bottom: 5, height: 1.38),
    h3: block(18, FontWeight.w700, top: 10, bottom: 4, height: 1.45),
    quote: DefaultTextBlockStyle(
      TextStyle(
        color: color.withValues(alpha: .78),
        fontSize: 15.5,
        height: 1.55,
        fontFamily: HuahuoV3Theme.fontFamily,
        fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
      ),
      const HorizontalSpacing(14, 8),
      const VerticalSpacing(6, 6),
      lineSpacing,
      BoxDecoration(
        color: tokens.surfaceMuted,
        border: Border(left: BorderSide(color: tokens.muted, width: 3)),
      ),
    ),
    code: DefaultTextBlockStyle(
      TextStyle(
        color: tokens.text,
        fontSize: 15,
        height: 1.55,
        fontFamily: 'Menlo',
        fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
      ),
      const HorizontalSpacing(12, 12),
      const VerticalSpacing(8, 8),
      lineSpacing,
      BoxDecoration(
        color: tokens.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    inlineCode: InlineCodeStyle(
      style: TextStyle(
        color: tokens.text,
        fontSize: 15,
        fontFamily: 'Menlo',
        fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
      ),
      backgroundColor: tokens.surfaceMuted,
      radius: const Radius.circular(4),
    ),
    link: TextStyle(
      color: tokens.accent,
      decoration: TextDecoration.underline,
      fontFamily: HuahuoV3Theme.fontFamily,
      fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    ),
    placeHolder: DefaultTextBlockStyle(
      TextStyle(
        color: tokens.muted,
        fontSize: 16,
        height: 1.55,
        fontFamily: HuahuoV3Theme.fontFamily,
        fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
      ),
      horizontal,
      const VerticalSpacing(3, 3),
      lineSpacing,
      null,
    ),
    color: color,
  );
}

Color _canvasDeletedColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFFFB4AB)
    : const Color(0xFFB42318);

Color _canvasInsertedColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF81C995)
    : const Color(0xFF137333);

class _CanvasDiffLegend extends StatelessWidget {
  const _CanvasDiffLegend({
    required this.icon,
    required this.label,
    required this.color,
    this.strikethrough = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool strikethrough;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 17, color: color)),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            decoration: strikethrough ? TextDecoration.lineThrough : null,
            decorationColor: color,
            decorationThickness: strikethrough ? 2 : null,
            letterSpacing: 0,
          ),
        ),
      ],
    ),
  );
}

class _CanvasAiFailure extends StatelessWidget {
  const _CanvasAiFailure({
    required this.errorCode,
    required this.onRetry,
    required this.onRegenerate,
  });

  final String? errorCode;
  final VoidCallback? onRetry;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 18, 10, 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, size: 32),
        const SizedBox(height: 10),
        Text(switch (errorCode) {
          'CANVAS_AI_SOURCE_CHANGED' => '正文已发生变化，请重新选择后生成。',
          'CANVAS_AI_PREVIEW_INVALID' => '建议无法安全显示，正文未被修改，请重新生成。',
          'CANVAS_AI_DIFF_INVALID' => '服务返回的修改与原文不匹配，正文未被修改，请重新生成。',
          'CANVAS_AI_RESPONSE_INVALID' => '服务返回的改写格式无效，正文未被修改。',
          'CANVAS_AI_RESULT_MISMATCH' => '改写不属于本次选中的原文，正文未被修改。',
          'AGENT_RUN_POLL_FAILED' => '暂时无法查询生成进度，可以重试同一次任务。',
          'CANVAS_AI_DIFF_FILE_UNAVAILABLE' => '服务返回的修改文件暂时无法读取，请重试。',
          'CANVAS_AI_DIFF_FILE_INVALID' => '服务返回的修改文件无效，正文未被修改。',
          'CANVAS_AI_DIFF_FILE_AMBIGUOUS' => '服务返回了多个修改文件，无法确认要应用的内容。',
          'CANVAS_AI_DIFF_REQUIRED' => '服务未返回可验证的修改文件，正文未被修改。',
          'CANVAS_AI_DIFF_TOO_LARGE' => '服务返回的修改内容过大，正文未被修改。',
          'CANVAS_AI_EMPTY_RESULT' => '改写结果为空，已拒绝清空正文。请重新生成。',
          'CANVAS_AI_NO_CHANGES' => '本次建议没有产生任何修改，请重新生成。',
          'CANVAS_AI_INVALID_LINE_BREAKS' => 'AI 返回了异常换行文本，正文未被修改。请重新生成。',
          _ =>
            onRetry != null ? '暂时无法获取生成结果，可重试同一次任务，正文未被修改。' : '暂时无法生成，正文未被修改。',
        }, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
        if (onRegenerate != null) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRegenerate,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新生成'),
          ),
        ],
      ],
    ),
  );
}

class _CanvasChatPanel extends ConsumerStatefulWidget {
  const _CanvasChatPanel({
    required this.documentContext,
    required this.rewriteTarget,
    required this.startFresh,
    required this.showTopGlow,
    required this.initialThreadId,
    required this.captureRewriteBaseline,
    required this.rewriteBaselineForMessage,
    required this.pendingTurn,
    required this.onTurnPrepared,
    required this.onThreadReadyToSubmit,
    required this.onMessageKnownRejected,
    required this.onTurnAccepted,
    required this.onTurnAbandoned,
    required this.onRejectedTurnEnd,
    required this.onThreadChanged,
    required this.onProposeRewrite,
    required this.onUseSkill,
    required this.onOpenTask,
  });

  final ValueGetter<String> documentContext;
  final _CanvasChatRewriteTarget? rewriteTarget;
  final bool startFresh;
  final bool showTopGlow;
  final String? initialThreadId;
  final ValueGetter<_CanvasChatRewriteBaseline?> captureRewriteBaseline;
  final _CanvasChatRewriteBaseline? Function(String messageId)
  rewriteBaselineForMessage;
  final ValueGetter<_CanvasChatPendingRewriteTurn?> pendingTurn;
  final Future<bool> Function(
    _CanvasChatRewriteBaseline baseline,
    String userMessageId,
    String requestText,
  )
  onTurnPrepared;
  final Future<bool> Function(String threadId, String userMessageId)
  onThreadReadyToSubmit;
  final Future<void> Function(String userMessageId) onMessageKnownRejected;
  final void Function(
    String threadId,
    String userMessageId,
    String? agentRunId,
    String? acceptedUserMessageId,
  )
  onTurnAccepted;
  final Future<bool> Function(String userMessageId) onTurnAbandoned;
  final Future<bool> Function(String userMessageId) onRejectedTurnEnd;
  final ValueChanged<String> onThreadChanged;
  final void Function(String suggestion, _CanvasChatRewriteBaseline baseline)
  onProposeRewrite;
  final Future<void> Function(
    CanvasAiAction action,
    _CanvasChatRewriteBaseline baseline,
  )
  onUseSkill;
  final Future<void> Function(String taskId) onOpenTask;

  @override
  ConsumerState<_CanvasChatPanel> createState() => _CanvasChatPanelState();
}

class _CanvasChatPanelState extends ConsumerState<_CanvasChatPanel> {
  late final TextEditingController _input;
  bool _preparingSource = false;
  late bool _freshThreadPending;
  bool _freshThreadReadyScheduled = false;
  final Set<String> _offeredDiffMessageIds = <String>{};

  @override
  void initState() {
    super.initState();
    _input = TextEditingController();
    _freshThreadPending = widget.startFresh;
    if (!widget.startFresh) {
      _offeredDiffMessageIds.addAll(
        ref
            .read(creationCanvasChatControllerProvider)
            .state
            .messages
            .map((message) => message.messageId),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(creationCanvasChatControllerProvider);
      final initialThreadId = widget.initialThreadId;
      if (_freshThreadPending) {
        _scheduleFreshThreadReady(controller);
      } else if (initialThreadId != null &&
          controller.state.activeThreadId != initialThreadId) {
        unawaited(controller.selectThread(initialThreadId));
      }
    });
  }

  void _scheduleFreshThreadReady(ChatController controller) {
    if (!_freshThreadPending ||
        _freshThreadReadyScheduled ||
        controller.state.isSending ||
        controller.state.activeThreadId != null ||
        controller.state.messages.isNotEmpty) {
      return;
    }
    _freshThreadReadyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _freshThreadReadyScheduled = false;
      if (!mounted || !_freshThreadPending) return;
      final current = ref.read(creationCanvasChatControllerProvider);
      if (current.state.isSending ||
          current.state.activeThreadId != null ||
          current.state.messages.isNotEmpty) {
        return;
      }
      setState(() => _freshThreadPending = false);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(creationCanvasChatControllerProvider);
    final state = controller.state;
    if (_freshThreadPending) _scheduleFreshThreadReady(controller);
    final pendingTurn = widget.pendingTurn();
    final controllerOwnsPendingTurn =
        pendingTurn != null &&
        state.turnState.userMessageId == pendingTurn.userMessageId;
    final hasDurableNonAdmissionProof =
        pendingTurn?.submissionPhase ==
        CreationCanvasChatSubmissionPhase.prepared;
    final canEndPendingTurn =
        pendingTurn != null &&
        (controller.canAbandonFailedTextMessage(
              pendingTurn.userMessageId,
              hasDurableNonAdmissionProof: hasDurableNonAdmissionProof,
            ) ||
            (hasDurableNonAdmissionProof && !controllerOwnsPendingTurn));
    final tokens = HuahuoV3Theme.tokensOf(context);
    final hasDraft = widget.documentContext().trim().isNotEmpty;
    final sourceMessages = _freshThreadPending
        ? const <ChatMessage>[]
        : state.messages;
    if (!_freshThreadPending && !state.isSending && pendingTurn == null) {
      _offerReturnedDiff(sourceMessages);
    }
    final messages = sourceMessages.length <= 30
        ? sourceMessages
        : sourceMessages.sublist(sourceMessages.length - 30);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactKeyboard =
            MediaQuery.viewInsetsOf(context).bottom > 0 &&
            constraints.maxHeight < 220;
        final compactIconConstraints = compactKeyboard
            ? const BoxConstraints.tightFor(width: 40, height: 40)
            : null;
        return Column(
          children: [
            if (widget.showTopGlow) const _CanvasChatLuminousEdge(),
            Padding(
              padding: compactKeyboard
                  ? const EdgeInsets.fromLTRB(12, 0, 4, 0)
                  : const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '创作聊天',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('canvas-chat-history'),
                    tooltip: '历史对话',
                    constraints: compactIconConstraints,
                    padding: compactKeyboard ? const EdgeInsets.all(8) : null,
                    onPressed: _showHistory,
                    icon: const Icon(Icons.history_rounded),
                  ),
                  IconButton(
                    key: const ValueKey<String>('canvas-chat-close'),
                    tooltip: '关闭',
                    constraints: compactIconConstraints,
                    padding: compactKeyboard ? const EdgeInsets.all(8) : null,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (!compactKeyboard)
              Padding(
                key: const ValueKey<String>('canvas-chat-context-chip'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    avatar: const Icon(Icons.description_outlined, size: 16),
                    label: Text(
                      widget.rewriteTarget != null
                          ? '当前选中文字'
                          : hasDraft
                          ? '当前正文'
                          : '正文为空',
                    ),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                    backgroundColor: tokens.surfaceMuted,
                  ),
                ),
              ),
            if (!compactKeyboard)
              SizedBox(
                height: 46,
                child: ListView(
                  key: const ValueKey<String>('canvas-chat-skills'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final action in CanvasAiAction.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          key: ValueKey<String>(
                            'canvas-chat-skill-${action.name}',
                          ),
                          label: Text(action.label),
                          onPressed:
                              state.isSending ||
                                  pendingTurn != null ||
                                  !hasDraft
                              ? null
                              : () => _useSkill(action),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(child: Text('写下问题，继续深化当前内容'))
                  : ListView.separated(
                      reverse: true,
                      padding: EdgeInsets.fromLTRB(
                        14,
                        compactKeyboard ? 2 : 8,
                        14,
                        compactKeyboard ? 2 : 16,
                      ),
                      itemCount: messages.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final message = messages[messages.length - 1 - index];
                        final baseline = widget.rewriteBaselineForMessage(
                          message.messageId,
                        );
                        return _CanvasChatMessage(
                          message: message,
                          agentProgressDrafts: controller.agentProgressDrafts,
                          onProposeRewrite:
                              message.role == ChatMessageRole.assistant &&
                                  baseline != null
                              ? (suggestion) => widget.onProposeRewrite(
                                  suggestion,
                                  baseline,
                                )
                              : null,
                          selectionScoped:
                              baseline?.editScope == CanvasAiEditScope.local,
                        );
                      },
                    ),
            ),
            if (state.lastErrorCode != null ||
                (pendingTurn != null && !state.turnState.isActive))
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: compactKeyboard ? 0 : 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        pendingTurn == null
                            ? '发送失败，请稍后重试'
                            : canEndPendingTurn
                            ? '消息未发送，可重试或结束'
                            : '上一次消息尚未完成',
                        style: HuahuoV3Theme.meta.copyWith(
                          color: tokens.danger,
                        ),
                      ),
                    ),
                    if (pendingTurn != null)
                      TextButton(
                        key: const ValueKey<String>('canvas-chat-retry'),
                        onPressed:
                            _preparingSource ||
                                state.isSending ||
                                state.isLoading
                            ? null
                            : _retryPendingTurn,
                        child: const Text('重试'),
                      ),
                    if (canEndPendingTurn)
                      TextButton(
                        key: const ValueKey<String>('canvas-chat-abandon'),
                        onPressed: _preparingSource
                            ? null
                            : _endRejectedPendingTurn,
                        child: const Text('结束发送'),
                      ),
                  ],
                ),
              ),
            if (!compactKeyboard &&
                state.nextAction.type != ChatNextActionType.none)
              _CanvasChatNextAction(
                action: state.nextAction,
                onOpenTask: (taskId) {
                  Navigator.of(context).pop();
                  unawaited(widget.onOpenTask(taskId));
                },
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: compactKeyboard
                    ? const EdgeInsets.fromLTRB(8, 2, 8, 4)
                    : const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>('canvas-chat-input'),
                        controller: _input,
                        contextMenuBuilder: V3TextEditing.buildContextMenu,
                        minLines: 1,
                        maxLines: compactKeyboard
                            ? 1
                            : V3ChatComposerMetrics.maxVisibleLines,
                        scrollPhysics: const ClampingScrollPhysics(),
                        textInputAction: TextInputAction.newline,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            _canvasChatUserInputLimit,
                          ),
                        ],
                        decoration: InputDecoration(
                          hintText: '继续聊聊这段内容',
                          isDense: compactKeyboard,
                          contentPadding: compactKeyboard
                              ? const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                )
                              : null,
                        ),
                      ),
                    ),
                    SizedBox(width: compactKeyboard ? 6 : 8),
                    IconButton(
                      key: const ValueKey<String>('canvas-chat-send'),
                      tooltip: '发送',
                      constraints: compactIconConstraints,
                      padding: compactKeyboard ? EdgeInsets.zero : null,
                      onPressed:
                          _freshThreadPending ||
                              _preparingSource ||
                              pendingTurn != null ||
                              !state.canSubmitUserTurn
                          ? null
                          : _send,
                      style: IconButton.styleFrom(
                        backgroundColor: tokens.accent,
                        foregroundColor:
                            ThemeData.estimateBrightnessForColor(
                                  tokens.accent,
                                ) ==
                                Brightness.dark
                            ? Colors.white
                            : tokens.canvas,
                        disabledBackgroundColor: tokens.surfaceMuted,
                        disabledForegroundColor: tokens.muted,
                      ),
                      icon: _preparingSource
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _offerReturnedDiff(List<ChatMessage> messages) {
    for (final message in messages.reversed) {
      if (message.role != ChatMessageRole.assistant ||
          !const {'sent', 'succeeded', 'completed'}.contains(message.status) ||
          _offeredDiffMessageIds.contains(message.messageId)) {
        continue;
      }
      final baseline = widget.rewriteBaselineForMessage(message.messageId);
      final content = message.visibleText;
      if (baseline == null || content == null) {
        continue;
      }
      try {
        if (canvasExtractUnifiedDiff(content) == null) continue;
      } on CanvasUnifiedDiffException {
        _offeredDiffMessageIds.add(message.messageId);
        continue;
      }
      _offeredDiffMessageIds.add(message.messageId);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final callback = widget.onProposeRewrite;
        Navigator.of(context).pop();
        await Future<void>.delayed(_canvasSheetDismissalDelay);
        callback(content, baseline);
      });
      return;
    }
  }

  Future<void> _useSkill(CanvasAiAction action) async {
    final baseline = widget.captureRewriteBaseline();
    if (baseline == null || baseline.sourceMarkdown.trim().isEmpty) {
      showV3Snack(context, '正文已变化或为空，请重新打开 AI 编辑');
      return;
    }
    final callback = widget.onUseSkill;
    Navigator.of(context).pop();
    await Future<void>.delayed(_canvasSheetDismissalDelay);
    await callback(action, baseline);
  }

  Future<void> _showHistory() async {
    if (widget.pendingTurn() != null) {
      showV3Snack(context, '请先完成上一次发送，再切换历史对话');
      return;
    }
    final controller = ref.read(creationCanvasChatControllerProvider);
    await controller.refreshCompleteHistory(force: true);
    if (!mounted) return;
    final entries = controller.historyThreads;
    final view = View.of(context);
    final logicalHeight =
        view.physicalSize.height /
        view.devicePixelRatio.clamp(1, double.infinity);
    final sheetHeight = (logicalHeight * .78).clamp(420.0, 720.0);
    final selected = await showV3GlassBottomSheet<ChatThread>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: sheetHeight,
        child: _CanvasChatHistoryPanel(entries: entries),
      ),
    );
    if (!mounted || selected == null) return;
    await controller.selectThread(selected.threadId);
    if (!mounted || controller.state.activeThreadId != selected.threadId) {
      return;
    }
    widget.onThreadChanged(selected.threadId);
  }

  ChatContextEnvelope? _chatContextForBaseline(
    _CanvasChatRewriteBaseline baseline,
  ) {
    final contextualSnapshot = baseline.chatContext.trim();
    final sourceSnapshot = baseline.sourceMarkdown.trim();
    final snapshotContent =
        contextualSnapshot.isNotEmpty &&
            contextualSnapshot.length <= ChatLocalDraftSnapshot.maxContentLength
        ? contextualSnapshot
        : sourceSnapshot;
    final localSnapshot = ChatLocalDraftSnapshot.create(
      kind: 'creation_canvas',
      content: snapshotContent,
      revision: 'revision-${baseline.documentRevision}',
    );
    if (localSnapshot == null) return null;
    return ChatContextEnvelope.create(
      purpose: ChatContextPurpose.general,
      entryPoint: ChatContextEntryPoint(
        surface: 'creation_canvas',
        entityType: baseline.editScope == CanvasAiEditScope.global
            ? 'document'
            : 'selection',
        entityId: 'revision-${baseline.documentRevision}',
      ),
      includeAccountProfile: false,
      localDraftSnapshot: localSnapshot,
    );
  }

  Future<void> _retryPendingTurn() async {
    final pending = widget.pendingTurn();
    if (pending == null || _preparingSource || _freshThreadPending) return;
    final controller = ref.read(creationCanvasChatControllerProvider);
    if (controller.state.isSending || controller.state.isLoading) return;
    final threadId = pending.threadId;
    if (threadId != null && controller.state.activeThreadId != threadId) {
      await controller.selectThread(threadId);
      if (!mounted || controller.state.activeThreadId != threadId) return;
    }
    setState(() => _preparingSource = true);
    try {
      final bool retried;
      if (controller.canRetryFailedTextMessage(pending.userMessageId)) {
        retried = await controller.retryFailedTextMessage(
          pending.userMessageId,
        );
      } else {
        final requestText = pending.requestText;
        final chatContext = _chatContextForBaseline(pending.baseline);
        if (requestText == null || chatContext == null) {
          showV3Snack(context, '该历史请求无法安全重放，请等待对话同步');
          return;
        }
        retried = await controller.sendText(
          requestText,
          context: chatContext,
          localMessageId: pending.userMessageId,
          recoverFailedLocalMessage: true,
          createThreadIdempotencyKey: pending.createThreadIdempotencyKey,
          messageIdempotencyKey: pending.messageIdempotencyKey,
          beforeMessageSubmit: (threadId) =>
              widget.onThreadReadyToSubmit(threadId, pending.userMessageId),
          onMessageKnownRejected: () =>
              widget.onMessageKnownRejected(pending.userMessageId),
        );
      }
      final acceptedState = controller.state;
      final acceptedThreadId = acceptedState.activeThreadId;
      final acceptedUserId = acceptedState.turnState.userMessageId;
      if (acceptedThreadId != null &&
          (retried || acceptedUserId == pending.userMessageId)) {
        widget.onTurnAccepted(
          acceptedThreadId,
          pending.userMessageId,
          acceptedState.turnState.agentRunId,
          acceptedUserId,
        );
        widget.onThreadChanged(acceptedThreadId);
      } else if (!retried && mounted) {
        showV3Snack(context, '上一次消息暂时无法恢复，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _preparingSource = false);
    }
  }

  Future<void> _endRejectedPendingTurn() async {
    final pending = widget.pendingTurn();
    if (pending == null || _preparingSource) return;
    final controller = ref.read(creationCanvasChatControllerProvider);
    final controllerOwnsTurn =
        controller.state.turnState.userMessageId == pending.userMessageId;
    final hasDurableNonAdmissionProof =
        pending.submissionPhase == CreationCanvasChatSubmissionPhase.prepared;
    if (controllerOwnsTurn &&
        !controller.canAbandonFailedTextMessage(
          pending.userMessageId,
          hasDurableNonAdmissionProof: hasDurableNonAdmissionProof,
        )) {
      return;
    }
    if (!controllerOwnsTurn && !hasDurableNonAdmissionProof) {
      return;
    }
    setState(() => _preparingSource = true);
    try {
      await widget.onRejectedTurnEnd(pending.userMessageId);
    } finally {
      if (mounted) setState(() => _preparingSource = false);
    }
  }

  Future<void> _send() async {
    final value = _input.text.trim();
    if (value.isEmpty || _preparingSource || _freshThreadPending) return;
    if (widget.pendingTurn() != null) return;
    final controller = ref.read(creationCanvasChatControllerProvider);
    if (!controller.state.canSubmitUserTurn) return;
    if (value.length > _canvasChatUserInputLimit) {
      showV3Snack(context, '单次最多发送 $_canvasChatUserInputLimit 个字符');
      return;
    }
    final rewriteBaseline = widget.captureRewriteBaseline();
    if (rewriteBaseline == null) {
      showV3Snack(context, '当前正文快照已变化，请重新打开创作聊天');
      return;
    }
    final documentContext = rewriteBaseline.chatContext.trim();
    final snapshotContent = rewriteBaseline.sourceMarkdown.trim();
    if (documentContext.isEmpty || snapshotContent.isEmpty) {
      showV3Snack(context, '先写下一些内容，再开始创作聊天');
      return;
    }
    if (rewriteBaseline.editScope == CanvasAiEditScope.global &&
        snapshotContent.length > ChatLocalDraftSnapshot.maxContentLength) {
      showV3Snack(context, '正文超过 12000 字，请先选择要讨论的段落');
      return;
    }
    final chatContext = _chatContextForBaseline(rewriteBaseline);
    if (chatContext == null) {
      showV3Snack(context, '当前正文无法作为聊天上下文，请检查内容后重试');
      return;
    }
    final onTurnAccepted = widget.onTurnAccepted;
    final onTurnAbandoned = widget.onTurnAbandoned;
    final onThreadChanged = widget.onThreadChanged;
    setState(() => _preparingSource = true);
    try {
      final requestHead = <String>[
        creationCanvasChatScopeInstruction,
        value,
      ].join('\n\n');
      final requestText = _truncateWithoutSplitting(
        requestHead,
        _canvasChatTransportTextLimit,
      );
      final userMessageId = controller.reserveTextMessageId();
      final prepared = await widget.onTurnPrepared(
        rewriteBaseline,
        userMessageId,
        requestText,
      );
      if (!prepared) return;
      final preparedTurn = widget.pendingTurn();
      if (preparedTurn == null || preparedTurn.userMessageId != userMessageId) {
        return;
      }
      final sent = await controller.sendText(
        requestText,
        context: chatContext,
        localMessageId: userMessageId,
        createThreadIdempotencyKey: preparedTurn.createThreadIdempotencyKey,
        messageIdempotencyKey: preparedTurn.messageIdempotencyKey,
        beforeMessageSubmit: (threadId) =>
            widget.onThreadReadyToSubmit(threadId, userMessageId),
        onMessageKnownRejected: () =>
            widget.onMessageKnownRejected(userMessageId),
      );
      final acceptedState = controller.state;
      final threadId = acceptedState.activeThreadId;
      final ownsVisibleTurn =
          acceptedState.turnState.userMessageId == userMessageId;
      if (threadId != null && (sent || ownsVisibleTurn)) {
        onTurnAccepted(
          threadId,
          userMessageId,
          acceptedState.turnState.agentRunId,
          acceptedState.turnState.userMessageId,
        );
        onThreadChanged(threadId);
      } else if (!sent && !ownsVisibleTurn) {
        await onTurnAbandoned(userMessageId);
      }
      if (mounted && (sent || ownsVisibleTurn)) {
        _input.clear();
      }
    } finally {
      if (mounted) setState(() => _preparingSource = false);
    }
  }
}

class _CanvasChatHistoryPanel extends StatelessWidget {
  const _CanvasChatHistoryPanel({required this.entries});

  final List<ChatThread> entries;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Text(
                '历史对话',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              Positioned(
                left: 8,
                child: V3NavigationBackButton(
                  key: const ValueKey<String>('canvas-chat-history-back'),
                  tooltip: '返回创作聊天',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Text(
            '最近对话',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    '暂无聊天记录',
                    style: TextStyle(color: tokens.muted, fontSize: 14),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: tokens.line),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _CanvasChatHistoryRow(
                      entry: entry,
                      onTap: () => Navigator.of(context).pop(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CanvasChatHistoryRow extends StatelessWidget {
  const _CanvasChatHistoryRow({required this.entry, required this.onTap});

  final ChatThread entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final excerpt = entry.firstUserMessageText?.trim().replaceAll('\n', ' ');
    return Material(
      key: ValueKey<String>('canvas-chat-history-${entry.threadId}'),
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                excerpt == null || excerpt.isEmpty ? '继续这次对话' : excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                entry.updatedAt == null
                    ? '自由创作'
                    : '自由创作 · ${_canvasHistoryTime(entry.updatedAt!)}',
                style: TextStyle(color: tokens.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _canvasHistoryTime(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _CanvasChatNextAction extends StatelessWidget {
  const _CanvasChatNextAction({required this.action, required this.onOpenTask});

  final ChatNextAction action;
  final ValueChanged<String> onOpenTask;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final taskId = action.taskId;
    final canOpenTask = taskId != null && isSafeChatIdentifier(taskId);
    final label = _chatNextActionLabel(action);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: tokens.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.pending_actions_outlined, size: 18, color: tokens.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: HuahuoV3Theme.meta)),
          if (canOpenTask)
            TextButton(
              onPressed: () => onOpenTask(taskId),
              child: const Text('查看任务'),
            ),
        ],
      ),
    );
  }
}

class _CanvasChatMessage extends StatelessWidget {
  const _CanvasChatMessage({
    required this.message,
    required this.agentProgressDrafts,
    required this.onProposeRewrite,
    required this.selectionScoped,
  });

  final ChatMessage message;
  final ValueListenable<Map<String, String>> agentProgressDrafts;
  final ValueChanged<String>? onProposeRewrite;
  final bool selectionScoped;

  @override
  Widget build(BuildContext context) {
    if (message.status == 'streaming') {
      return ValueListenableBuilder<Map<String, String>>(
        valueListenable: agentProgressDrafts,
        builder: (context, drafts, _) => _buildMessage(
          context,
          drafts[message.messageId] ?? message.visibleText ?? '',
          isStreaming: true,
        ),
      );
    }
    return _buildMessage(
      context,
      message.visibleText?.trim(),
      isStreaming: false,
    );
  }

  Widget _buildMessage(
    BuildContext context,
    String? text, {
    required bool isStreaming,
  }) {
    if (text == null || text.trim().isEmpty) return const SizedBox.shrink();
    final user = message.role == ChatMessageRole.user;
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          crossAxisAlignment: user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: user ? tokens.primary : tokens.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: user
                  ? Text(
                      text,
                      style: TextStyle(color: tokens.onPrimary, height: 1.45),
                    )
                  : V3AssistantReplyMarkdown(
                      key: ValueKey<String>(
                        'canvas-chat-assistant-markdown-${message.messageId}',
                      ),
                      source: text,
                    ),
            ),
            if (!user && !isStreaming)
              Wrap(
                spacing: 2,
                runSpacing: 0,
                children: [
                  IconButton(
                    tooltip: V3TextEditing.copyLabel,
                    onPressed: () => V3TextEditing.copy(context, text),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                  if (onProposeRewrite != null)
                    TextButton.icon(
                      key: const ValueKey<String>(
                        'canvas-chat-rewrite-proposal',
                      ),
                      onPressed: () => _handoffToRewriteProposal(context, text),
                      icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                      label: Text(selectionScoped ? '改写选中内容' : '生成修改对比'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handoffToRewriteProposal(
    BuildContext context,
    String text,
  ) async {
    final callback = onProposeRewrite;
    if (callback == null) return;
    Navigator.of(context).pop();
    await Future<void>.delayed(_canvasSheetDismissalDelay);
    callback(text);
  }
}

class _CanvasDividerEmbedBuilder extends EmbedBuilder {
  const _CanvasDividerEmbedBuilder({required this.reviewing});

  final bool reviewing;

  @override
  String get key => CanvasDocumentCodec.canvasDividerEmbedType;

  @override
  String toPlainText(Embed node) => '\n---\n';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final change = reviewing
        ? CanvasAiInlineReview.changeFor(embedContext.node.style.toJson())
        : null;
    final divider = Padding(
      key: const ValueKey<String>('canvas-divider-embed'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Divider(
        height: 1,
        thickness: change == null ? 1 : 2,
        color: switch (change) {
          CanvasReviewChange.deleted => _canvasDeletedColor(context),
          CanvasReviewChange.inserted => _canvasInsertedColor(context),
          null => HuahuoV3Theme.tokensOf(context).line,
        },
      ),
    );
    if (change == null) return divider;
    return _CanvasReviewEmbedFrame(
      key: ValueKey<String>(
        'canvas-review-${change.name}-divider-${embedContext.node.documentOffset}',
      ),
      change: change,
      contentLabel: '分隔线',
      child: divider,
    );
  }
}

class _CanvasImageEmbedBuilder extends EmbedBuilder {
  const _CanvasImageEmbedBuilder({
    required this.reviewing,
    required this.selectedImageId,
    required this.enabled,
    required this.onSelected,
    required this.onWidthChanged,
  });

  final bool reviewing;
  final String? selectedImageId;
  final bool enabled;
  final void Function(String resourceId, int offset) onSelected;
  final void Function(int offset, CanvasImageEmbedData data) onWidthChanged;

  @override
  String get key => CanvasImageEmbedData.deltaEmbedType;

  @override
  String toPlainText(Embed node) {
    try {
      return '[图片：${_imageData(node).alt}]';
    } on FormatException {
      return '[图片]';
    }
  }

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    try {
      final data = _imageData(embedContext.node);
      final image = _CanvasResizableImage(
        key: ValueKey<String>('canvas-image-${data.resourceId}'),
        data: data,
        documentOffset: embedContext.node.documentOffset,
        selected: selectedImageId == data.resourceId,
        enabled: enabled && !embedContext.readOnly,
        onSelected: () =>
            onSelected(data.resourceId, embedContext.node.documentOffset),
        onWidthChanged: (next) =>
            onWidthChanged(embedContext.node.documentOffset, next),
      );
      final change = reviewing
          ? CanvasAiInlineReview.changeFor(embedContext.node.style.toJson())
          : null;
      if (change == null) return image;
      return _CanvasReviewEmbedFrame(
        key: ValueKey<String>(
          'canvas-review-${change.name}-image-${data.resourceId}',
        ),
        change: change,
        contentLabel: '图片 ${data.alt}',
        child: image,
      );
    } on FormatException {
      return const SizedBox(
        height: 104,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 28)),
      );
    }
  }

  CanvasImageEmbedData _imageData(Embed node) {
    final data = node.value.data;
    if (data is! Map) {
      throw const FormatException('Canvas image embed payload is invalid');
    }
    return CanvasImageEmbedData.fromJson(
      data.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
}

class _CanvasReviewEmbedFrame extends StatelessWidget {
  const _CanvasReviewEmbedFrame({
    required this.change,
    required this.contentLabel,
    required this.child,
    super.key,
  });

  final CanvasReviewChange change;
  final String contentLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final deleted = change == CanvasReviewChange.deleted;
    final color = deleted
        ? _canvasDeletedColor(context)
        : _canvasInsertedColor(context);
    final changeLabel = deleted ? '删除内容' : '新增内容';
    return Semantics(
      container: true,
      label: '$changeLabel：$contentLabel',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  deleted
                      ? Icons.remove_circle_outline_rounded
                      : Icons.add_circle_outline_rounded,
                  color: color,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  changeLabel,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Stack(
              children: [
                Opacity(opacity: deleted ? .55 : 1, child: child),
                if (deleted)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: Container(height: 3, color: color)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CanvasResizableImage extends StatefulWidget {
  const _CanvasResizableImage({
    required this.data,
    required this.documentOffset,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    required this.onWidthChanged,
    super.key,
  });

  final CanvasImageEmbedData data;
  final int documentOffset;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;
  final ValueChanged<CanvasImageEmbedData> onWidthChanged;

  @override
  State<_CanvasResizableImage> createState() => _CanvasResizableImageState();
}

class _CanvasResizableImageState extends State<_CanvasResizableImage> {
  late double _widthRatio;
  late Future<File?> _imageFile;
  double _availableWidth = 1;

  @override
  void initState() {
    super.initState();
    _widthRatio = widget.data.widthRatio;
    _imageFile = _resolveCanvasPrivateImageById(widget.data.resourceId);
  }

  @override
  void didUpdateWidget(covariant _CanvasResizableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.resourceId != widget.data.resourceId) {
      _imageFile = _resolveCanvasPrivateImageById(widget.data.resourceId);
    }
    if (oldWidget.data.widthRatio != widget.data.widthRatio) {
      _widthRatio = widget.data.widthRatio;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: '图片 ${widget.data.alt}，当前宽度 ${(_widthRatio * 100).round()}%',
    onTap: widget.enabled ? widget.onSelected : null,
    customSemanticsActions: widget.enabled
        ? <CustomSemanticsAction, VoidCallback>{
            const CustomSemanticsAction(label: '放大图片'): () =>
                _commitWidth(_widthRatio + .1),
            const CustomSemanticsAction(label: '缩小图片'): () =>
                _commitWidth(_widthRatio - .1),
          }
        : null,
    child: LayoutBuilder(
      builder: (context, constraints) {
        _availableWidth = math.max(1, constraints.maxWidth);
        final width = _availableWidth * _widthRatio;
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? widget.onSelected : null,
            child: SizedBox(
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  FutureBuilder<File?>(
                    future: _imageFile,
                    builder: (context, snapshot) {
                      final file = snapshot.data;
                      if (file == null) {
                        return const SizedBox(
                          height: 108,
                          child: Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        );
                      }
                      return AspectRatio(
                        aspectRatio: widget.data.aspectRatio,
                        child: Image.file(
                          file,
                          fit: BoxFit.contain,
                          cacheWidth: _canvasImageCacheExtent(context, width),
                          cacheHeight: _canvasImageCacheExtent(
                            context,
                            width / widget.data.aspectRatio,
                          ),
                          semanticLabel: widget.data.alt,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      );
                    },
                  ),
                  if (widget.selected && widget.enabled) ...[
                    _buildHandle('top-left', Alignment.topLeft, -1, -1),
                    _buildHandle('top-right', Alignment.topRight, 1, -1),
                    _buildHandle('bottom-left', Alignment.bottomLeft, -1, 1),
                    _buildHandle('bottom-right', Alignment.bottomRight, 1, 1),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _buildHandle(
    String name,
    Alignment alignment,
    double horizontalDirection,
    double verticalDirection,
  ) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: GestureDetector(
          key: ValueKey<String>(
            'canvas-image-handle-$name-${widget.data.resourceId}',
          ),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            final horizontal = details.delta.dx * horizontalDirection;
            final vertical =
                details.delta.dy * verticalDirection * widget.data.aspectRatio;
            final delta = horizontal.abs() >= vertical.abs()
                ? horizontal
                : vertical;
            _previewWidth(_widthRatio + delta / _availableWidth);
          },
          onPanEnd: (_) => _commitWidth(_widthRatio),
          onPanCancel: () =>
              setState(() => _widthRatio = widget.data.widthRatio),
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: tokens.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.ink, width: 1.4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _previewWidth(double value) {
    final minimum = math.max(
      CanvasImageEmbedData.minimumWidthRatio,
      math.min(1, 96 / _availableWidth),
    );
    final normalized = value.clamp(minimum, 1).toDouble();
    if (normalized == _widthRatio) return;
    setState(() => _widthRatio = normalized);
  }

  void _commitWidth(double value) {
    _previewWidth(value);
    if (_widthRatio == widget.data.widthRatio) return;
    widget.onWidthChanged(widget.data.copyWith(widthRatio: _widthRatio));
  }
}

class _CanvasFloatingChatEntry extends StatelessWidget {
  const _CanvasFloatingChatEntry({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: '聊一聊',
      child: SizedBox.square(
        key: const ValueKey<String>('canvas-chat-entry'),
        dimension: 44,
        child: Material(
          color: tokens.canvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: tokens.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: const Center(child: V3ChatMark(size: 36)),
          ),
        ),
      ),
    );
  }
}

class _CanvasAiActionButton extends StatelessWidget {
  const _CanvasAiActionButton({
    required this.action,
    required this.onPressed,
    super.key,
  });

  final CanvasAiAction action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.ink,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: BorderSide(color: tokens.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: Icon(_actionIcon(action), size: 17),
          label: Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

class _CanvasToolButton extends StatelessWidget {
  const _CanvasToolButton({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.label,
    this.child,
    this.selected = false,
    super.key,
  }) : assert(icon != null || label != null || child != null);

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? label;
  final Widget? child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final activeSelected = selected && onPressed != null;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: activeSelected,
      label: tooltip,
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          style: activeSelected
              ? IconButton.styleFrom(
                  foregroundColor: tokens.ink,
                  backgroundColor: tokens.surfaceMuted,
                )
              : null,
          icon:
              child ??
              (label == null
                  ? Icon(icon, size: 20)
                  : Text(
                      label!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    )),
        ),
      ),
    );
  }
}

int _canvasImageCacheExtent(BuildContext context, double logicalExtent) =>
    (logicalExtent * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 4096)
        .toInt();

class _CanvasChatLuminousEdge extends StatelessWidget {
  const _CanvasChatLuminousEdge();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('canvas-chat-top-glow'),
      height: 12,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: 30,
              right: 30,
              top: 0,
              height: 3,
              child: DecoratedBox(
                key: const ValueKey<String>('canvas-chat-top-glow-source'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    stops: const <double>[0, .5, 1],
                    colors: <Color>[
                      Colors.transparent,
                      HuahuoV3Theme.tokensOf(
                        context,
                      ).accent.withValues(alpha: .72),
                      Colors.transparent,
                    ],
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: HuahuoV3Theme.tokensOf(
                        context,
                      ).accent.withValues(alpha: .20),
                      blurRadius: 12,
                      spreadRadius: 3,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isAiBusy(CanvasAiTransformStatus status) =>
    status == CanvasAiTransformStatus.running ||
    status == CanvasAiTransformStatus.awaitingCompletion ||
    status == CanvasAiTransformStatus.previewing ||
    status == CanvasAiTransformStatus.applying;

String _truncateWithoutSplitting(String value, int maxCodeUnits) {
  if (maxCodeUnits <= 0) return '';
  if (value.length <= maxCodeUnits) return value;
  var end = maxCodeUnits;
  if (end < value.length &&
      value.codeUnitAt(end - 1) >= 0xD800 &&
      value.codeUnitAt(end - 1) <= 0xDBFF &&
      value.codeUnitAt(end) >= 0xDC00 &&
      value.codeUnitAt(end) <= 0xDFFF) {
    end -= 1;
  }
  return value.substring(0, end);
}

String _chatNextActionLabel(ChatNextAction action) {
  final serverMessage = action.userMessage?.trim();
  if (serverMessage != null && serverMessage.isNotEmpty) return serverMessage;
  return switch (action.type) {
    ChatNextActionType.openTaskPanel ||
    ChatNextActionType.pollTask => 'AI 正在继续处理，可进入任务页查看进度。',
    ChatNextActionType.pollAgentRun ||
    ChatNextActionType.pollThread => 'AI 正在生成回复，请稍后刷新。',
    ChatNextActionType.quotaInsufficient => '当前额度不足，本次请求尚未继续处理。',
    ChatNextActionType.pollAsr => '语音内容仍在识别，请稍后再试。',
    ChatNextActionType.retryAsr => '语音识别失败，可以重新提交。',
    ChatNextActionType.none => '',
  };
}

String _resolvedTitle(String rawTitle, String markdown) {
  final title = rawTitle.trim();
  if (title.isNotEmpty) return title;
  for (final line in markdown.split('\n')) {
    final value = line
        .replaceFirst(RegExp(r'^\s*(?:#{1,6}|[-+*>]|\d+[.)])\s*'), '')
        .trim();
    if (value.isNotEmpty) {
      return value.length <= 60 ? value : value.substring(0, 60);
    }
  }
  return '未命名创作';
}

String? _clean(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _newCanvasSessionId() =>
    'canvas-session-${DateTime.now().toUtc().microsecondsSinceEpoch}';

String? _historyIdentityFromEntry(String? entryIdentity) {
  const prefix = 'history:';
  if (entryIdentity == null || !entryIdentity.startsWith(prefix)) return null;
  return _clean(entryIdentity.substring(prefix.length));
}

bool _sameCanvasLinkedMaterialIds(
  Iterable<V3LinkedMaterialRef> left,
  Iterable<V3LinkedMaterialRef> right,
) {
  final leftIds = left.map((item) => '${item.source.name}:${item.id}').toSet();
  final rightIds = right
      .map((item) => '${item.source.name}:${item.id}')
      .toSet();
  return setEquals(leftIds, rightIds);
}

bool _sameCanvasLinkedMaterials(
  List<V3LinkedMaterialRef> left,
  List<V3LinkedMaterialRef> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final leftItem = left[index];
    final rightItem = right[index];
    if (leftItem.id != rightItem.id ||
        leftItem.source != rightItem.source ||
        leftItem.title != rightItem.title ||
        leftItem.summary != rightItem.summary) {
      return false;
    }
  }
  return true;
}

String _initialDraftProgressLabel(ScriptDraftGenerationPhase phase) =>
    switch (phase) {
      ScriptDraftGenerationPhase.idle => '正在准备生成',
      ScriptDraftGenerationPhase.resolving => '正在恢复生成进度',
      ScriptDraftGenerationPhase.creatingThread => '正在创建创作会话',
      ScriptDraftGenerationPhase.submitting => '正在提交选题内容',
      ScriptDraftGenerationPhase.streaming => '正在接收逐字稿，完成前不会写入正文',
      ScriptDraftGenerationPhase.ready => '正在校验最终稿',
      ScriptDraftGenerationPhase.failed => '生成失败',
      ScriptDraftGenerationPhase.cancelled => '生成已取消',
    };

String _initialDraftFailureMessage(String? code) => switch (code) {
  'SCRIPT_DRAFT_BACKEND_UNAVAILABLE' => '初稿服务当前不可用，请稍后重试。',
  'SCRIPT_DRAFT_FINAL_ANSWER_REQUIRED' => '服务未返回完整成稿，请重试。',
  'SCRIPT_DRAFT_RECEIPT_PERSIST_FAILED' => '生成进度无法保存，请检查本地存储后重试。',
  _ => '暂时无法生成逐字稿，来源正文和局部结果均未写入编辑器。',
};

IconData _actionIcon(CanvasAiAction action) => switch (action) {
  CanvasAiAction.socialRelationShift => Icons.people_outline_rounded,
  CanvasAiAction.needsDeepening => Icons.travel_explore_rounded,
  CanvasAiAction.differentiationStrengthening => Icons.difference_rounded,
  CanvasAiAction.openingOptimization => Icons.first_page_rounded,
  CanvasAiAction.expansion => Icons.unfold_more_rounded,
  CanvasAiAction.personaInsertion => Icons.person_pin_outlined,
  CanvasAiAction.imageBrief => Icons.image_outlined,
  CanvasAiAction.atomization => Icons.account_tree_outlined,
};

String _actionSubtitle(CanvasAiAction action) => switch (action) {
  CanvasAiAction.socialRelationShift => '调整称呼、视角和表达语气',
  CanvasAiAction.needsDeepening => '补全动机、影响和完成标准',
  CanvasAiAction.differentiationStrengthening => '突出定位、方法和证据缺口',
  CanvasAiAction.openingOptimization => '使用标签化或陌生化开头',
  CanvasAiAction.expansion => '在不改变事实的前提下展开',
  CanvasAiAction.personaInsertion => '带入社媒定位中的身份和价值',
  CanvasAiAction.imageBrief => '生成可编辑的 Markdown 配图建议',
  CanvasAiAction.atomization => '拆成一段一个观点的内容块',
};
