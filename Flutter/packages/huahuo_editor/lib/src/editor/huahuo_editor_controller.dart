import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/huahuo_document.dart';
import '../document/huahuo_document_codec.dart';

typedef HuahuoDocumentSaver =
    Future<void> Function(HuahuoDocumentSnapshot snapshot);

enum HuahuoSaveState { saved, dirty, saving, failed }

final class HuahuoEditorController extends ChangeNotifier {
  HuahuoEditorController({
    required HuahuoDocumentSnapshot initial,
    required this.onSave,
    this.autosaveDelay = const Duration(milliseconds: 800),
  }) : _id = initial.id,
       _createdAt = initial.createdAt,
       _revision = initial.revision,
       _linkedMaterials = initial.linkedMaterials,
       _sourceTopicId = initial.sourceTopicId,
       _sourceTopicTitle = initial.sourceTopicTitle,
       _summaryMarkdown = initial.summaryMarkdown,
       _sproutMarkdown = initial.sproutMarkdown,
       _aiAnnotations = List<HuahuoAiAnnotation>.unmodifiable(
         initial.aiAnnotations,
       ),
       title = TextEditingController(text: initial.title),
       body = QuillController(
         document: initial.toDocument(),
         selection: const TextSelection.collapsed(offset: 0),
       ) {
    title.addListener(_handleTitleChanged);
    _bodyChanges = body.changes.listen(_handleBodyChanged);
  }

  final String _id;
  final DateTime _createdAt;
  final List<HuahuoLinkedMaterialRef> _linkedMaterials;
  final String? _sourceTopicId;
  final String? _sourceTopicTitle;
  final String? _summaryMarkdown;
  final String? _sproutMarkdown;
  List<HuahuoAiAnnotation> _aiAnnotations;
  final HuahuoDocumentSaver onSave;
  final Duration autosaveDelay;
  final TextEditingController title;
  final QuillController body;

  StreamSubscription<DocChange>? _bodyChanges;
  Timer? _autosaveTimer;
  HuahuoSaveState _saveState = HuahuoSaveState.saved;
  int _revision;
  bool _saving = false;
  bool _saveRequested = false;

  HuahuoSaveState get saveState => _saveState;
  int get revision => _revision;

  HuahuoDocumentSnapshot get snapshot => HuahuoDocumentSnapshot(
    id: _id,
    title: title.text.trim(),
    deltaJson: HuahuoDocumentCodec.encode(body.document),
    revision: _revision,
    createdAt: _createdAt,
    modifiedAt: DateTime.now().toUtc(),
    markdownProjection: HuahuoDocumentCodec.documentToMarkdown(body.document),
    linkedMaterials: _linkedMaterials,
    sourceTopicId: _sourceTopicId,
    sourceTopicTitle: _sourceTopicTitle,
    summaryMarkdown: _summaryMarkdown,
    sproutMarkdown: _sproutMarkdown,
    aiAnnotations: _aiAnnotations,
  );

  void toggleAttribute(Attribute<dynamic> attribute) {
    final current = body.getSelectionStyle().attributes[attribute.key];
    body.formatSelection(
      current?.value == attribute.value
          ? Attribute.clone(attribute, null)
          : attribute,
    );
  }

  void undo() {
    if (body.hasUndo) body.undo();
  }

  void redo() {
    if (body.hasRedo) body.redo();
  }

  void insertAtCursor(String text) {
    if (text.isEmpty) return;
    final selection = body.selection;
    final documentEnd = body.document.length - 1;
    final start = selection.start.clamp(0, documentEnd);
    final end = selection.end.clamp(start, documentEnd);
    body.replaceText(
      start,
      end - start,
      text,
      TextSelection.collapsed(offset: start + text.length),
    );
  }

  void replaceAiAnnotations(Iterable<HuahuoAiAnnotation> annotations) {
    _aiAnnotations = List<HuahuoAiAnnotation>.unmodifiable(annotations);
    _markChanged();
  }

  Future<void> saveNow() async {
    _autosaveTimer?.cancel();
    if (_saving) {
      _saveRequested = true;
      return;
    }
    _saving = true;
    _setSaveState(HuahuoSaveState.saving);
    try {
      final pending = snapshot;
      await onSave(pending);
      _setSaveState(
        _revision == pending.revision
            ? HuahuoSaveState.saved
            : HuahuoSaveState.dirty,
      );
    } on Object {
      _setSaveState(HuahuoSaveState.failed);
    } finally {
      _saving = false;
      if (_saveRequested) {
        _saveRequested = false;
        unawaited(saveNow());
      }
    }
  }

  void _handleTitleChanged() => _markChanged();

  void _handleBodyChanged(DocChange change) {
    if (change.source == ChangeSource.local) _markChanged();
  }

  void _markChanged() {
    _revision += 1;
    _setSaveState(HuahuoSaveState.dirty);
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(autosaveDelay, () => unawaited(saveNow()));
  }

  void _setSaveState(HuahuoSaveState value) {
    if (_saveState == value) return;
    _saveState = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    title
      ..removeListener(_handleTitleChanged)
      ..dispose();
    unawaited(_bodyChanges?.cancel());
    body.dispose();
    super.dispose();
  }
}
