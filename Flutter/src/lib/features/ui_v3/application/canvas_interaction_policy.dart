import 'package:flutter/foundation.dart';

import '../domain/canvas_ai_models.dart';

enum CanvasEditingMode { edit, ai }

enum CanvasSaveAction { none, save, continuePending }

enum CanvasLeaveResolution {
  leaveImmediately,
  decideDraft,
  resolveLink,
  resolveAi,
  preserveSaveTransaction,
  waitForCriticalOperation,
}

enum CanvasSaveIndicator {
  none,
  localDraft,
  unsavedChanges,
  cloudSaved,
  saving,
  recoveryPending,
  localWriteFailed,
}

/// Projects Canvas runtime facts into a single interaction capability matrix.
///
/// This object is deliberately side-effect free. Callers remain responsible for
/// persistence, cancellation, navigation, and applying editor mutations.
@immutable
final class CanvasInteractionPolicy {
  const CanvasInteractionPolicy({
    this.editingMode = CanvasEditingMode.edit,
    this.isInitializing = false,
    this.isDirty = false,
    this.hasBodyContent = false,
    this.isLinkEditing = false,
    this.aiStatus = CanvasAiTransformStatus.idle,
    this.isVoiceEngaged = false,
    this.hasPendingChat = false,
    this.hasPendingSaveReceipt = false,
    this.isSaving = false,
    this.isLeaveSettlementInProgress = false,
    this.isEntryTransitionInProgress = false,
    this.hasPersistedLocalDraft = false,
    this.localDraftWriteFailed = false,
    this.cloudSaveVerified = false,
    this.needsCloudSave = false,
    this.isBoundNote = false,
  });

  final CanvasEditingMode editingMode;
  final bool isInitializing;
  final bool isDirty;
  final bool hasBodyContent;
  final bool isLinkEditing;
  final CanvasAiTransformStatus aiStatus;
  final bool isVoiceEngaged;
  final bool hasPendingChat;
  final bool hasPendingSaveReceipt;
  final bool isSaving;
  final bool isLeaveSettlementInProgress;
  final bool isEntryTransitionInProgress;
  final bool hasPersistedLocalDraft;
  final bool localDraftWriteFailed;
  final bool cloudSaveVerified;
  final bool needsCloudSave;
  final bool isBoundNote;

  bool get aiNeedsResolution => switch (aiStatus) {
    CanvasAiTransformStatus.running ||
    CanvasAiTransformStatus.awaitingCompletion ||
    CanvasAiTransformStatus.previewing => true,
    CanvasAiTransformStatus.idle ||
    CanvasAiTransformStatus.applying ||
    CanvasAiTransformStatus.failed ||
    CanvasAiTransformStatus.cancelled => false,
  };

  bool get hardBlocksLeave =>
      isSaving ||
      isLeaveSettlementInProgress ||
      isEntryTransitionInProgress ||
      aiStatus == CanvasAiTransformStatus.applying;

  bool get locksEditor =>
      isInitializing ||
      hardBlocksLeave ||
      isVoiceEngaged ||
      aiNeedsResolution ||
      hasPendingSaveReceipt;

  /// Whether a new save command is blocked.
  ///
  /// A durable save receipt intentionally does not set this flag: it replaces
  /// the normal save command with the one allowed recovery action.
  bool get locksSave =>
      isInitializing ||
      hardBlocksLeave ||
      isLinkEditing ||
      isVoiceEngaged ||
      aiNeedsResolution;

  bool get canEditDocument => !locksEditor;

  bool get canUseEditorCommands => canEditDocument && !isLinkEditing;

  bool get canSwitchEditingMode =>
      canUseEditorCommands && !hasPendingSaveReceipt;

  bool get canStartLinkEditing =>
      canUseEditorCommands && !hasPendingSaveReceipt;

  bool get canResolveLink => isLinkEditing && !hardBlocksLeave;

  bool get canStartAi => canUseEditorCommands && !hasPendingSaveReceipt;

  bool get canOpenChat => canUseEditorCommands && !hasPendingSaveReceipt;

  bool get canStartChat => canOpenChat && !hasPendingChat;

  CanvasSaveAction get saveAction {
    if (locksSave) return CanvasSaveAction.none;
    if (hasPendingSaveReceipt) return CanvasSaveAction.continuePending;
    if ((isDirty || needsCloudSave) && hasBodyContent) {
      return CanvasSaveAction.save;
    }
    return CanvasSaveAction.none;
  }

  bool get canSave => saveAction != CanvasSaveAction.none;

  bool get canContinuePendingSave =>
      saveAction == CanvasSaveAction.continuePending;

  CanvasLeaveResolution get leaveResolution {
    if (hardBlocksLeave || isInitializing) {
      return CanvasLeaveResolution.waitForCriticalOperation;
    }
    if (hasPendingSaveReceipt) {
      return CanvasLeaveResolution.preserveSaveTransaction;
    }
    if (isLinkEditing) return CanvasLeaveResolution.resolveLink;
    if (aiNeedsResolution) return CanvasLeaveResolution.resolveAi;
    if (isVoiceEngaged) {
      return CanvasLeaveResolution.waitForCriticalOperation;
    }
    if (isDirty || localDraftWriteFailed) {
      return CanvasLeaveResolution.decideDraft;
    }
    return CanvasLeaveResolution.leaveImmediately;
  }

  CanvasSaveIndicator get saveIndicator {
    if (isSaving) return CanvasSaveIndicator.saving;
    if (hasPendingSaveReceipt) return CanvasSaveIndicator.recoveryPending;
    if (localDraftWriteFailed) {
      return CanvasSaveIndicator.localWriteFailed;
    }
    if (isDirty) {
      if (isBoundNote) return CanvasSaveIndicator.unsavedChanges;
      return hasPersistedLocalDraft
          ? CanvasSaveIndicator.localDraft
          : CanvasSaveIndicator.none;
    }
    if (cloudSaveVerified) return CanvasSaveIndicator.cloudSaved;
    if (hasPersistedLocalDraft || needsCloudSave) {
      return CanvasSaveIndicator.localDraft;
    }
    return CanvasSaveIndicator.none;
  }
}
