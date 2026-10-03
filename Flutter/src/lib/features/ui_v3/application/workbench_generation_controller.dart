import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';

import '../data/workbench_generation_repository.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';
import 'knowledge_library_controller.dart';

// resident-provider: Preserves the workbench generation controller state machine across route transitions.
final workbenchGenerationControllerProvider =
    ChangeNotifierProvider<WorkbenchGenerationController>((ref) {
      ref.watch(authenticatedUserDataScopeProvider);
      ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.workspace?.workspaceId,
        ),
      );
      return WorkbenchGenerationController(
        library: ref.watch(knowledgeLibraryControllerProvider.notifier),
        repository: ref.watch(workbenchGenerationRepositoryProvider),
      );
    });

enum WorkbenchGenerationTaskStatus {
  processing,
  awaitingResult,
  succeeded,
  failed,
}

@immutable
final class WorkbenchGenerationTask {
  WorkbenchGenerationTask({
    required this.id,
    required this.purpose,
    required List<V3FeedItem> notes,
    required this.startedAt,
    required this.status,
    this.result,
    this.errorCode,
    this.requiresNewOperation = false,
  }) : notes = List.unmodifiable(notes);

  final String id;
  final WorkbenchPurpose purpose;
  final List<V3FeedItem> notes;
  final DateTime startedAt;
  final WorkbenchGenerationTaskStatus status;
  final WorkbenchGenerationResult? result;
  final String? errorCode;
  final bool requiresNewOperation;

  WorkbenchGenerationTask withOutcome(
    WorkbenchGenerationTaskStatus status, {
    WorkbenchGenerationResult? result,
    String? errorCode,
    bool requiresNewOperation = false,
  }) => WorkbenchGenerationTask(
    id: id,
    purpose: purpose,
    notes: notes,
    startedAt: startedAt,
    status: status,
    result: result,
    errorCode: errorCode,
    requiresNewOperation: requiresNewOperation,
  );
}

final class WorkbenchGenerationController extends ChangeNotifier {
  static const maxSelectedNotes = 2;

  WorkbenchGenerationController({
    required KnowledgeLibraryController library,
    required WorkbenchGenerationRepository repository,
  }) : // Named constructor arguments intentionally keep their public names.
       // ignore: prefer_initializing_formals
       _library = library,
       // ignore: prefer_initializing_formals
       _repository = repository;

  final KnowledgeLibraryController _library;
  final WorkbenchGenerationRepository _repository;
  final Set<String> _selectedNoteIds = <String>{};

  WorkbenchPurpose? _purpose;
  WorkbenchGenerationStatus _status = WorkbenchGenerationStatus.idle;
  WorkbenchNoteFilter _filter = WorkbenchNoteFilter.all;
  String _query = '';
  String? _resultMarkdown;
  DateTime? _generatedAt;
  String? _errorCode;
  int _generationToken = 0;
  int _operationSequence = 0;
  String? _generationId;
  DateTime? _generationStartedAt;
  final Map<String, WorkbenchGenerationTask> _tasks = {};
  int _taskRevision = 0;

  WorkbenchPurpose? get purpose => _purpose;
  WorkbenchGenerationStatus get status => _status;
  WorkbenchNoteFilter get filter => _filter;
  String get query => _query;
  Set<String> get selectedNoteIds => Set<String>.unmodifiable(_selectedNoteIds);
  int get selectedCount => _selectedNoteIds.length;
  String? get resultMarkdown => _resultMarkdown;
  DateTime? get generatedAt => _generatedAt;
  String? get generationId => _generationId;
  DateTime? get generationStartedAt => _generationStartedAt;
  int get taskRevision => _taskRevision;
  List<WorkbenchGenerationTask> get tasks => List.unmodifiable(_tasks.values);
  WorkbenchGenerationTask? taskForId(String? id) => _tasks[id];
  String? get errorCode => _errorCode;
  bool get canGenerate =>
      _selectedNoteIds.isNotEmpty &&
      _status != WorkbenchGenerationStatus.generating;

  List<V3FeedItem> get hotspotNotes => _filteredNotes(hotspot: true);
  List<V3FeedItem> get normalNotes => _filteredNotes(hotspot: false);
  List<V3FeedItem> get selectedNotes => _selectedNoteIds
      .map(_library.noteForId)
      .whereType<V3FeedItem>()
      .toList(growable: false);

  void startSelection(WorkbenchPurpose purpose) {
    if (_status == WorkbenchGenerationStatus.generating) return;
    _generationToken += 1;
    _purpose = purpose;
    _status = WorkbenchGenerationStatus.selecting;
    _filter = WorkbenchNoteFilter.mine;
    _query = '';
    _errorCode = null;
    _resultMarkdown = null;
    _generatedAt = null;
    _generationId = null;
    _generationStartedAt = null;
    _selectedNoteIds.clear();
    notifyListeners();
  }

  void setQuery(String value) {
    final normalized = value.trim();
    if (_query == normalized) return;
    _query = normalized;
    notifyListeners();
  }

  void setFilter(WorkbenchNoteFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
  }

  bool toggleNote(String noteId) {
    if (_status == WorkbenchGenerationStatus.generating) return false;
    if (_library.noteForId(noteId) == null) return false;
    if (_selectedNoteIds.remove(noteId)) {
      notifyListeners();
      return true;
    }
    if (_selectedNoteIds.length >= maxSelectedNotes) return false;
    _selectedNoteIds.add(noteId);
    notifyListeners();
    return true;
  }

  void replaceSelection(Iterable<String> noteIds) {
    if (_status == WorkbenchGenerationStatus.generating) return;
    final next = <String>{};
    for (final noteId in noteIds) {
      if (_library.noteForId(noteId) == null ||
          next.length >= maxSelectedNotes) {
        continue;
      }
      next.add(noteId);
    }
    if (setEquals(next, _selectedNoteIds)) return;
    _selectedNoteIds
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void consumeSelection() {
    if (_status == WorkbenchGenerationStatus.generating) return;
    if (_selectedNoteIds.isEmpty) return;
    _selectedNoteIds.clear();
    notifyListeners();
  }

  Future<bool> generate() => _generate();

  Future<bool> _generate({
    WorkbenchGenerationTask? source,
    bool retry = false,
  }) async {
    if (_status == WorkbenchGenerationStatus.generating) return false;
    final purpose = source?.purpose ?? _purpose;
    if (purpose == null) return false;
    final notes = source?.notes ?? selectedNotes;
    if (notes.isEmpty) return false;
    final token = ++_generationToken;
    _status = WorkbenchGenerationStatus.generating;
    _errorCode = null;

    final operationId = retry && source != null
        ? source.id
        : _nextOperationId(purpose);
    final task = WorkbenchGenerationTask(
      id: operationId,
      purpose: purpose,
      notes: notes,
      startedAt: retry && source != null
          ? source.startedAt
          : DateTime.now().toUtc(),
      status: WorkbenchGenerationTaskStatus.processing,
    );
    _purpose = purpose;
    _selectedNoteIds
      ..clear()
      ..addAll(notes.map((note) => note.id));
    _resultMarkdown = null;
    _generatedAt = null;
    _generationId = operationId;
    _generationStartedAt = task.startedAt;
    _recordTask(task);
    notifyListeners();
    try {
      final result = await _repository.generate(
        purpose: purpose,
        notes: notes,
        operationId: operationId,
      );
      if (token != _generationToken) return false;
      _resultMarkdown = result.markdown;
      _generatedAt = result.generatedAt;
      _status = WorkbenchGenerationStatus.succeeded;
      _recordTask(
        task.withOutcome(
          WorkbenchGenerationTaskStatus.succeeded,
          result: result,
        ),
      );
      notifyListeners();
      return true;
    } on WorkbenchGenerationException catch (error) {
      if (token != _generationToken) return false;
      _status = WorkbenchGenerationStatus.failed;
      _errorCode = error.code;
      _recordTask(
        task.withOutcome(
          error.resultPending
              ? WorkbenchGenerationTaskStatus.awaitingResult
              : WorkbenchGenerationTaskStatus.failed,
          errorCode: error.code,
          requiresNewOperation: error.terminalFailure,
        ),
      );
      notifyListeners();
      return false;
    } catch (_) {
      if (token != _generationToken) return false;
      _status = WorkbenchGenerationStatus.failed;
      _errorCode = 'WORKBENCH_GENERATION_FAILED';
      _recordTask(
        task.withOutcome(
          WorkbenchGenerationTaskStatus.failed,
          errorCode: _errorCode,
        ),
      );
      notifyListeners();
      return false;
    }
  }

  void _recordTask(WorkbenchGenerationTask task) {
    _tasks[task.id] = task;
    _taskRevision += 1;
  }

  Future<bool> retry([String? operationId]) {
    final task = taskForId(operationId ?? _generationId);
    if (task == null ||
        !const {
          WorkbenchGenerationTaskStatus.failed,
          WorkbenchGenerationTaskStatus.awaitingResult,
        }.contains(task.status)) {
      return Future.value(false);
    }
    return _generate(source: task, retry: !task.requiresNewOperation);
  }

  Future<bool> regenerate(String operationId) {
    final task = taskForId(operationId);
    if (task == null ||
        task.status != WorkbenchGenerationTaskStatus.succeeded) {
      return Future.value(false);
    }
    return _generate(source: task);
  }

  void clearForWorkbench() {
    if (_status == WorkbenchGenerationStatus.generating) return;
    _generationToken++;
    _purpose = null;
    _status = WorkbenchGenerationStatus.idle;
    _selectedNoteIds.clear();
    _query = '';
    _filter = WorkbenchNoteFilter.all;
    _resultMarkdown = null;
    _generatedAt = null;
    _errorCode = null;
    _generationId = null;
    _generationStartedAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _generationToken += 1;
    super.dispose();
  }

  String _nextOperationId(WorkbenchPurpose purpose) {
    _operationSequence += 1;
    return 'workbench-${purpose.routeName}-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_operationSequence';
  }

  List<V3FeedItem> _filteredNotes({required bool hotspot}) {
    final notes =
        _library.allDepositedNotes.where((note) {
          if (note.isHotspot != hotspot) return false;
          return _matchesQuery(note);
        }).toList()..sort((a, b) {
          final createdAt = b.createdAt.compareTo(a.createdAt);
          return createdAt == 0 ? a.id.compareTo(b.id) : createdAt;
        });
    return List<V3FeedItem>.unmodifiable(notes);
  }

  bool _matchesQuery(V3FeedItem note) {
    final query = _query.toLowerCase();
    if (query.isEmpty) return true;
    return <String?>[
      note.title,
      note.rawBody,
      note.summaryBody,
      note.source.label,
      note.contentLineName,
      note.folderName,
    ].whereType<String>().any((value) => value.toLowerCase().contains(query));
  }
}
