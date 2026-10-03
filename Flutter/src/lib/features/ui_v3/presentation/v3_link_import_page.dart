import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../ingestion/application/material_ingestion_coordinator.dart';
import '../../ingestion/domain/material_ingestion.dart';
import 'v3_deposit_picker.dart';
import 'v3_material_import_surfaces.dart';

typedef MaterialClipboardTextReader = Future<String?> Function();

class V3LinkImportPage extends ConsumerStatefulWidget {
  const V3LinkImportPage({
    this.clipboardTextReader = readMaterialClipboardText,
    this.freshEntry = false,
    this.initialDraftId,
    super.key,
  });

  final MaterialClipboardTextReader clipboardTextReader;
  final bool freshEntry;
  final String? initialDraftId;

  @override
  ConsumerState<V3LinkImportPage> createState() => _V3LinkImportPageState();
}

class _V3LinkImportPageState extends ConsumerState<V3LinkImportPage>
    with AppActivityRouteAware<V3LinkImportPage> {
  final _url = TextEditingController();
  String? _draftId;
  String? _pendingAdoptionId;
  String? _pendingInputHydrationId;
  String? _validationError;
  String? _openedNoteId;
  String? _scheduledNoteId;
  bool _distillToDigitalTwin = false;

  @override
  void initState() {
    super.initState();
    _draftId = _safeDraftId(widget.initialDraftId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefillClipboardUrl());
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(materialIngestionCoordinatorProvider);
    final draft = _selectedDraft(coordinator);
    _scheduleCompletedNoteHandoff(draft);
    if (widget.initialDraftId != null && draft == null) {
      return V3MaterialImportRouteSheet(
        title: '链接导入任务',
        confirmLabel: '关闭',
        onClose: _close,
        onConfirm: _close,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(24, 28, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.task_alt_rounded, size: 42),
              SizedBox(height: 14),
              Text(
                '该链接任务已结束或当前不可恢复',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text('可以关闭此窗口，并在资产或消息中心查看最新结果。', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final refreshing =
        draft != null && coordinator.isRefreshingLinkTask(draft.id);
    final busy = draft?.isBusy == true || refreshing;
    final retryCurrent = _canRetryCurrentDraft(draft);
    if (busy || draft?.status == MaterialIngestionStatus.completed) {
      return V3MaterialImportProgressSurface(
        sourceLabel: draft?.normalizedUrl ?? _url.text.trim(),
        sourceIcon: Icons.link_rounded,
        title: draft?.status == MaterialIngestionStatus.completed
            ? '笔记已生成'
            : refreshing
            ? '正在查询链接任务...'
            : '链接分析中...',
        message: draft?.status == MaterialIngestionStatus.completed
            ? '正在打开生成的笔记。'
            : refreshing
            ? '仅查询已提交任务的状态，不会重新执行链接分析。'
            : '正在读取并分析链接内容，视频与长内容可能需要更久。',
        onBack: _close,
        canReturnViaNotifications: busy && draft != null,
      );
    }
    return V3MaterialImportRouteSheet(
      title: '从链接导入',
      confirmLabel: retryCurrent
          ? draft!.remoteTaskId != null
                ? '刷新状态'
                : '重试'
          : '确定',
      onClose: _close,
      onConfirm: retryCurrent ? () => coordinator.retry(draft!.id) : _submit,
      child: V3LinkImportSheetContent(
        controller: _url,
        distillToDigitalTwin: _distillToDigitalTwin,
        onDistillationChanged: (value) =>
            setState(() => _distillToDigitalTwin = value),
        onDistillationHelp: () => showV3DistillationHelpSheet(context),
        errorText:
            _validationError ??
            (draft?.status == MaterialIngestionStatus.failed
                ? _statusDetail(draft!)
                : null),
        onChanged: (_) => setState(() => _validationError = null),
      ),
    );
  }

  void _close() {
    unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
  }

  Future<void> _submit() async {
    final uri = normalizeMaterialUrl(_url.text);
    if (uri == null) {
      setState(() => _validationError = '请输入有效的 http 或 https 链接');
      return;
    }
    FocusScope.of(context).unfocus();
    final coordinator = ref.read(materialIngestionCoordinatorProvider);
    final existing = coordinator.drafts
        .where(
          (item) => item.id == _draftId && item.normalizedUrl == uri.toString(),
        )
        .firstOrNull;
    final draft = existing ?? await coordinator.submitLink(uri.toString());
    if (!mounted) return;
    if (draft == null) {
      setState(() => _validationError = '暂时无法创建导入任务，请稍后重试');
      return;
    }
    _draftId = draft.id;
    if (_distillToDigitalTwin) {
      final queued = await ref
          .read(digitalTwinMaterialControllerProvider)
          .enqueue(
            referenceKind: 'ingestion',
            referenceId: draft.id,
            title: uri.toString(),
          );
      if (!mounted) return;
      if (!queued) {
        setState(() => _validationError = '链接已受理，但材料排队未保存，请重试排队');
        return;
      }
    }
    setState(() {
      _draftId = draft.id;
      _url.value = TextEditingValue(
        text: uri.toString(),
        selection: TextSelection.collapsed(offset: uri.toString().length),
      );
      _validationError = null;
    });
  }

  Future<void> _prefillClipboardUrl() async {
    if (!mounted || _url.text.trim().isNotEmpty) return;
    String? text;
    try {
      text = await widget.clipboardTextReader();
    } catch (_) {
      return;
    }
    if (!mounted || _url.text.trim().isNotEmpty) return;
    final normalized = _firstClipboardMaterialUrl(text);
    if (normalized == null) return;
    setState(() {
      _url.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
      _validationError = null;
    });
  }

  MaterialIngestionDraft? _selectedDraft(
    MaterialIngestionCoordinator coordinator,
  ) {
    final id = _draftId;
    if (id != null) {
      for (final draft in coordinator.drafts) {
        if (draft.id == id) {
          if (draft.source != MaterialIngestionSource.link ||
              draft.status == MaterialIngestionStatus.cancelled) {
            return null;
          }
          _scheduleDraftInputHydration(draft);
          return draft;
        }
      }
      return null;
    }
    if (widget.freshEntry || widget.initialDraftId != null) return null;
    final active = coordinator.activeDraft;
    if (active?.source == MaterialIngestionSource.link &&
        active?.isBusy == true) {
      _scheduleDraftAdoption(active!);
      return active;
    }
    for (final draft in coordinator.drafts) {
      if (draft.source == MaterialIngestionSource.link && draft.isBusy) {
        _scheduleDraftAdoption(draft);
        return draft;
      }
    }
    return null;
  }

  void _scheduleDraftAdoption(MaterialIngestionDraft draft) {
    if (_pendingAdoptionId == draft.id) return;
    _pendingAdoptionId = draft.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingAdoptionId = null;
      if (_draftId != null) return;
      setState(() {
        _draftId = draft.id;
        final normalizedUrl = draft.normalizedUrl;
        if (_url.text.trim().isEmpty && normalizedUrl != null) {
          _url.value = TextEditingValue(
            text: normalizedUrl,
            selection: TextSelection.collapsed(offset: normalizedUrl.length),
          );
        }
      });
    });
  }

  void _scheduleDraftInputHydration(MaterialIngestionDraft draft) {
    final normalizedUrl = draft.normalizedUrl;
    if (normalizedUrl == null ||
        _url.text.trim().isNotEmpty ||
        _pendingInputHydrationId == draft.id) {
      return;
    }
    _pendingInputHydrationId = draft.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingInputHydrationId = null;
      if (_draftId != draft.id || _url.text.trim().isNotEmpty) return;
      setState(() {
        _url.value = TextEditingValue(
          text: normalizedUrl,
          selection: TextSelection.collapsed(offset: normalizedUrl.length),
        );
      });
    });
  }

  bool _canRetryCurrentDraft(MaterialIngestionDraft? draft) {
    if (draft == null ||
        draft.id != _draftId ||
        draft.status != MaterialIngestionStatus.failed) {
      return false;
    }
    return normalizeMaterialUrl(_url.text)?.toString() == draft.normalizedUrl;
  }

  void _scheduleCompletedNoteHandoff(MaterialIngestionDraft? draft) {
    final noteId = draft?.noteId;
    if (draft?.status != MaterialIngestionStatus.completed ||
        noteId == null ||
        _openedNoteId == noteId ||
        _scheduledNoteId == noteId) {
      return;
    }
    _scheduledNoteId = noteId;
    final draftId = draft!.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
        if (_scheduledNoteId == noteId) _scheduledNoteId = null;
        return;
      }
      final current = ref
          .read(materialIngestionCoordinatorProvider)
          .drafts
          .where((candidate) => candidate.id == draftId)
          .firstOrNull;
      if (current?.status != MaterialIngestionStatus.completed ||
          current?.noteId != noteId ||
          _draftId != draftId) {
        if (_scheduledNoteId == noteId) _scheduledNoteId = null;
        return;
      }
      _scheduledNoteId = null;
      _openedNoteId = noteId;
      context.replace(AppRoutePaths.feedItem(noteId));
    });
  }

  @override
  void onActivityRouteBecameActive() {
    _scheduleCompletedNoteHandoff(
      _selectedDraft(ref.read(materialIngestionCoordinatorProvider)),
    );
  }
}

String? _safeDraftId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 160 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

Future<String?> readMaterialClipboardText() => V3TextEditing.readPlainText();

String? _firstClipboardMaterialUrl(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  final match = RegExp(
    "https?://[^\\s<>\"']+",
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  var candidate = match.group(0)!;
  while (candidate.isNotEmpty &&
      RegExp(r'[),.;!?，。；！？）】》]').hasMatch(candidate[candidate.length - 1])) {
    candidate = candidate.substring(0, candidate.length - 1);
  }
  return normalizeMaterialUrl(candidate)?.toString();
}

String _statusDetail(MaterialIngestionDraft draft) {
  if (draft.status != MaterialIngestionStatus.failed) {
    return draft.normalizedUrl ?? draft.title;
  }
  final code = draft.lastErrorCode ?? '';
  if (const <String>{
    'PYTHON_VERSION_UNSUPPORTED',
    'DEPENDENCY_UNAVAILABLE',
    'YTDLP_UNAVAILABLE',
    'URL_READER_CONFIG_INVALID',
    'CONFIG_INVALID',
  }.contains(code)) {
    return '链接解析服务配置异常，需要服务端修复；不是链接格式或公开权限问题。';
  }
  if (code == 'LINK_IMPORT_URL_INVALID') {
    return '链接格式无效，请检查后重试';
  }
  if (code == 'URL_IMPORT_INVALID') {
    return '链接无效或内容无法公开访问，请检查后重试';
  }
  if (code == 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED') {
    return '内容已解析，但保存失败，请重试';
  }
  if (code == 'WORKSPACE_CONTEXT_UNAVAILABLE') {
    return '工作空间尚未准备好，请稍后重试';
  }
  if (code.contains('LOGIN') ||
      code.contains('AUTH') ||
      code.contains('PAY') ||
      code.contains('PRIVATE') ||
      code.contains('FORBIDDEN')) {
    return '此内容可能需要登录、付费或访问权限，暂不支持导入';
  }
  if (code.contains('DELETED') || code.contains('NOT_FOUND')) {
    return '内容不存在或已删除，暂不支持导入';
  }
  if (code.contains('REGION')) {
    return '当前地区无法访问此内容，暂不支持导入';
  }
  if (code == 'LINK_IMPORT_SERVICE_UNAVAILABLE' ||
      code == 'LINK_IMPORT_CREATE_FAILED' ||
      code == 'LINK_IMPORT_POLL_FAILED' ||
      code == 'LINK_IMPORT_NOTE_READ_FAILED' ||
      code == 'LINK_IMPORT_TIMEOUT' ||
      code == 'NOTE_PROJECTION_FAILED' ||
      code.startsWith('NOTE_INGESTION_') ||
      code.contains('NETWORK') ||
      code.contains('TIMEOUT')) {
    return '暂时无法解析此链接，请稍后重试';
  }
  return '解析没有完成，请确认内容可公开访问后重试';
}
