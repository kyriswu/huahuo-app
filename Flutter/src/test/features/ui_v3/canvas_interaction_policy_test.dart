import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_interaction_policy.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';

void main() {
  test('clean and dirty states expose the expected save and leave actions', () {
    const clean = CanvasInteractionPolicy(
      hasBodyContent: true,
      cloudSaveVerified: true,
    );
    expect(clean.canEditDocument, isTrue);
    expect(clean.saveAction, CanvasSaveAction.none);
    expect(clean.leaveResolution, CanvasLeaveResolution.leaveImmediately);
    expect(clean.saveIndicator, CanvasSaveIndicator.cloudSaved);

    const dirty = CanvasInteractionPolicy(
      isDirty: true,
      hasBodyContent: true,
      hasPersistedLocalDraft: true,
    );
    expect(dirty.canSave, isTrue);
    expect(dirty.saveAction, CanvasSaveAction.save);
    expect(dirty.leaveResolution, CanvasLeaveResolution.decideDraft);
    expect(dirty.saveIndicator, CanvasSaveIndicator.localDraft);
  });

  test('a clean local asset can explicitly retry its cloud save', () {
    const policy = CanvasInteractionPolicy(
      hasBodyContent: true,
      hasPersistedLocalDraft: true,
      needsCloudSave: true,
    );

    expect(policy.saveAction, CanvasSaveAction.save);
    expect(policy.canSave, isTrue);
    expect(policy.saveIndicator, CanvasSaveIndicator.localDraft);
    expect(policy.leaveResolution, CanvasLeaveResolution.leaveImmediately);
  });

  test(
    'link editing owns commands, blocks save, and must resolve on leave',
    () {
      const policy = CanvasInteractionPolicy(
        isDirty: true,
        hasBodyContent: true,
        isLinkEditing: true,
      );

      expect(policy.locksSave, isTrue);
      expect(policy.saveAction, CanvasSaveAction.none);
      expect(policy.canUseEditorCommands, isFalse);
      expect(policy.canResolveLink, isTrue);
      expect(policy.leaveResolution, CanvasLeaveResolution.resolveLink);
    },
  );

  for (final status in <CanvasAiTransformStatus>[
    CanvasAiTransformStatus.running,
    CanvasAiTransformStatus.awaitingCompletion,
    CanvasAiTransformStatus.previewing,
  ]) {
    test('$status locks editing and save but leaves through AI resolution', () {
      final policy = CanvasInteractionPolicy(
        isDirty: true,
        hasBodyContent: true,
        aiStatus: status,
      );

      expect(policy.aiNeedsResolution, isTrue);
      expect(policy.locksEditor, isTrue);
      expect(policy.locksSave, isTrue);
      expect(policy.hardBlocksLeave, isFalse);
      expect(policy.leaveResolution, CanvasLeaveResolution.resolveAi);
    });
  }

  test('AI applying is a short critical hard lock', () {
    const policy = CanvasInteractionPolicy(
      aiStatus: CanvasAiTransformStatus.applying,
    );

    expect(policy.aiNeedsResolution, isFalse);
    expect(policy.hardBlocksLeave, isTrue);
    expect(policy.locksEditor, isTrue);
    expect(policy.locksSave, isTrue);
    expect(
      policy.leaveResolution,
      CanvasLeaveResolution.waitForCriticalOperation,
    );
  });

  test('voice settles before leave while pending Chat stays advisory', () {
    const voice = CanvasInteractionPolicy(isVoiceEngaged: true);
    expect(voice.hardBlocksLeave, isFalse);
    expect(voice.locksEditor, isTrue);
    expect(voice.locksSave, isTrue);
    expect(
      voice.leaveResolution,
      CanvasLeaveResolution.waitForCriticalOperation,
    );

    const chat = CanvasInteractionPolicy(
      isDirty: true,
      hasBodyContent: true,
      hasPendingChat: true,
      hasPersistedLocalDraft: true,
    );
    expect(chat.canEditDocument, isTrue);
    expect(chat.canOpenChat, isTrue);
    expect(chat.canStartChat, isFalse);
    expect(chat.canStartAi, isTrue);
    expect(chat.canStartLinkEditing, isTrue);
    expect(chat.canSwitchEditingMode, isTrue);
    expect(chat.locksSave, isFalse);
    expect(chat.saveAction, CanvasSaveAction.save);
    expect(chat.leaveResolution, CanvasLeaveResolution.decideDraft);
    expect(chat.saveIndicator, CanvasSaveIndicator.localDraft);
  });

  test('a pending Chat alone does not create an unsaved document state', () {
    const chat = CanvasInteractionPolicy(
      hasBodyContent: true,
      hasPendingChat: true,
      cloudSaveVerified: true,
    );

    expect(chat.canSave, isFalse);
    expect(chat.canStartChat, isFalse);
    expect(chat.canSwitchEditingMode, isTrue);
    expect(chat.leaveResolution, CanvasLeaveResolution.leaveImmediately);
    expect(chat.saveIndicator, CanvasSaveIndicator.cloudSaved);
  });

  test('dirty bound note is presented as an unsaved update', () {
    const policy = CanvasInteractionPolicy(
      isDirty: true,
      isBoundNote: true,
      hasBodyContent: true,
      hasPersistedLocalDraft: true,
    );

    expect(policy.canSave, isTrue);
    expect(policy.saveIndicator, CanvasSaveIndicator.unsavedChanges);
  });

  test('durable save receipt exposes only continue and may be preserved', () {
    const policy = CanvasInteractionPolicy(
      hasPendingSaveReceipt: true,
      hasBodyContent: false,
    );

    expect(policy.hardBlocksLeave, isFalse);
    expect(policy.locksEditor, isTrue);
    expect(policy.locksSave, isFalse);
    expect(policy.saveAction, CanvasSaveAction.continuePending);
    expect(policy.canContinuePendingSave, isTrue);
    expect(
      policy.leaveResolution,
      CanvasLeaveResolution.preserveSaveTransaction,
    );
    expect(policy.saveIndicator, CanvasSaveIndicator.recoveryPending);
  });

  test('saving takes precedence over a pending save receipt', () {
    const policy = CanvasInteractionPolicy(
      hasPendingSaveReceipt: true,
      isSaving: true,
    );

    expect(policy.hardBlocksLeave, isTrue);
    expect(policy.saveAction, CanvasSaveAction.none);
    expect(policy.canContinuePendingSave, isFalse);
    expect(policy.saveIndicator, CanvasSaveIndicator.saving);
    expect(
      policy.leaveResolution,
      CanvasLeaveResolution.waitForCriticalOperation,
    );
  });

  test('saving and leave settlement are critical operations', () {
    const saving = CanvasInteractionPolicy(isSaving: true);
    expect(saving.hardBlocksLeave, isTrue);
    expect(saving.saveAction, CanvasSaveAction.none);
    expect(saving.saveIndicator, CanvasSaveIndicator.saving);
    expect(
      saving.leaveResolution,
      CanvasLeaveResolution.waitForCriticalOperation,
    );

    const settling = CanvasInteractionPolicy(isLeaveSettlementInProgress: true);
    expect(settling.hardBlocksLeave, isTrue);
    expect(settling.locksEditor, isTrue);
  });

  test('local write failure is never presented as a cloud save', () {
    const policy = CanvasInteractionPolicy(
      isDirty: true,
      hasBodyContent: true,
      localDraftWriteFailed: true,
      cloudSaveVerified: true,
    );

    expect(policy.saveIndicator, CanvasSaveIndicator.localWriteFailed);
    expect(policy.leaveResolution, CanvasLeaveResolution.decideDraft);
    expect(policy.canSave, isTrue);
  });

  test('a newer local draft takes precedence over an older cloud baseline', () {
    const policy = CanvasInteractionPolicy(
      isDirty: true,
      hasBodyContent: true,
      hasPersistedLocalDraft: true,
      cloudSaveVerified: true,
    );

    expect(policy.saveIndicator, CanvasSaveIndicator.localDraft);
  });

  test('initialization and entry transitions keep commands unavailable', () {
    const initializing = CanvasInteractionPolicy(isInitializing: true);
    expect(initializing.locksEditor, isTrue);
    expect(initializing.locksSave, isTrue);
    expect(
      initializing.leaveResolution,
      CanvasLeaveResolution.waitForCriticalOperation,
    );

    const transitioning = CanvasInteractionPolicy(
      isEntryTransitionInProgress: true,
    );
    expect(transitioning.hardBlocksLeave, isTrue);
    expect(transitioning.canSwitchEditingMode, isFalse);
  });
}
