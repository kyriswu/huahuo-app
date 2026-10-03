import 'package:flutter/foundation.dart';

import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/v3_deposit_models.dart';

typedef KnowledgeNotesReader = List<V3FeedItem> Function();
typedef KnowledgeMembershipReader =
    bool Function(String contentId, V3LibraryCollection collection);
typedef KnowledgeNotePredicate = bool Function(V3FeedItem note);
typedef KnowledgeFolderNameReader = String? Function(String contentId);
typedef KnowledgeFolderIdReader = String? Function(String contentId);
typedef KnowledgeFolderExists = bool Function(String folderId);
typedef KnowledgeFolderNamesReader = List<String> Function();
typedef KnowledgeTagsReader = List<String> Function(V3FeedItem note);

/// Owns query/filter state and immutable derived Knowledge-library results.
///
/// Persistence and mutations stay outside this class. Typed readers make the
/// projection independently testable while preserving one authoritative note
/// and membership store in the account-lived facade.
final class KnowledgeLibraryQueryController extends ChangeNotifier {
  KnowledgeLibraryQueryController({
    required KnowledgeNotesReader notes,
    required KnowledgeMembershipReader hasMembership,
    required KnowledgeNotePredicate isDeposited,
    required KnowledgeFolderNameReader folderNameFor,
    required KnowledgeFolderIdReader folderIdFor,
    required KnowledgeFolderExists folderExists,
    required KnowledgeFolderNamesReader folderNames,
    required KnowledgeTagsReader effectiveTags,
    DateTime Function()? now,
  }) : _notes = notes,
       _hasMembership = hasMembership,
       _isDeposited = isDeposited,
       _folderNameFor = folderNameFor,
       _folderIdFor = folderIdFor,
       _folderExists = folderExists,
       _folderNames = folderNames,
       _effectiveTags = effectiveTags,
       _now = now ?? DateTime.now;

  final KnowledgeNotesReader _notes;
  final KnowledgeMembershipReader _hasMembership;
  final KnowledgeNotePredicate _isDeposited;
  final KnowledgeFolderNameReader _folderNameFor;
  final KnowledgeFolderIdReader _folderIdFor;
  final KnowledgeFolderExists _folderExists;
  final KnowledgeFolderNamesReader _folderNames;
  final KnowledgeTagsReader _effectiveTags;
  final DateTime Function() _now;

  V3KnowledgeLibraryTab _tab = V3KnowledgeLibraryTab.mine;
  final Map<V3KnowledgeLibraryTab, KnowledgeSourceCategory> _sourceCategories =
      <V3KnowledgeLibraryTab, KnowledgeSourceCategory>{
        for (final tab in V3KnowledgeLibraryTab.values)
          tab: KnowledgeSourceCategory.all,
      };
  KnowledgeSourceCategory _depositSourceCategory = KnowledgeSourceCategory.all;
  KnowledgeSourceFilter _sourceFilter = KnowledgeSourceFilter.all;
  KnowledgeTimeFilter _timeFilter = KnowledgeTimeFilter.all;
  KnowledgeDateRange? _customTimeRange;
  V3KnowledgeGrouping _grouping = V3KnowledgeGrouping.ownership;
  V3KnowledgeSort _sort = V3KnowledgeSort.recentlyUpdated;
  String _query = '';
  KnowledgeSourceFilter _depositSourceFilter = KnowledgeSourceFilter.all;
  KnowledgeTimeFilter _depositTimeFilter = KnowledgeTimeFilter.all;
  KnowledgeDateRange? _depositCustomTimeRange;
  V3KnowledgeGrouping _depositGrouping = V3KnowledgeGrouping.ownership;
  V3KnowledgeSort _depositSort = V3KnowledgeSort.recentlyUpdated;
  String _depositQuery = '';
  V3DepositFilterKind _depositFilterKind = V3DepositFilterKind.browse;
  String? _depositFolderFilterId;
  int _revision = 0;
  (int, V3KnowledgeLibraryTab, String)? _filteredNotesMemoKey;
  List<V3FeedItem>? _filteredNotesMemo;
  int _filteredDepositNotesMemoRevision = -1;
  List<V3FeedItem>? _filteredDepositNotesMemo;

  V3KnowledgeLibraryTab get tab => _tab;
  KnowledgeSourceCategory sourceCategoryFor(V3KnowledgeLibraryTab tab) =>
      tab == V3KnowledgeLibraryTab.mine
      ? _sourceCategories[V3KnowledgeLibraryTab.mine] ??
            KnowledgeSourceCategory.all
      : KnowledgeSourceCategory.all;
  KnowledgeSourceCategory get sourceCategory => sourceCategoryFor(_tab);
  KnowledgeSourceCategory get depositSourceCategory => _depositSourceCategory;
  KnowledgeSourceFilter get sourceFilter => _sourceFilter;
  KnowledgeTimeFilter get timeFilter => _timeFilter;
  KnowledgeDateRange? get customTimeRange => _customTimeRange;
  V3KnowledgeGrouping get grouping => _grouping;
  V3KnowledgeSort get sort => _sort;
  String get query => _query;
  KnowledgeSourceFilter get depositSourceFilter => _depositSourceFilter;
  KnowledgeTimeFilter get depositTimeFilter => _depositTimeFilter;
  KnowledgeDateRange? get depositCustomTimeRange => _depositCustomTimeRange;
  V3KnowledgeGrouping get depositGrouping => _depositGrouping;
  V3KnowledgeSort get depositSort => _depositSort;
  String get depositQuery => _depositQuery;
  V3DepositFilterKind get depositFilterKind => _depositFilterKind;
  String? get depositFolderFilterId => _depositFolderFilterId;

  /// Invalidates memoized projections after an authoritative domain change.
  /// This deliberately does not notify: the owning facade publishes once.
  void invalidate() {
    _revision += 1;
    _filteredNotesMemoKey = null;
    _filteredNotesMemo = null;
    _filteredDepositNotesMemoRevision = -1;
    _filteredDepositNotesMemo = null;
  }

  void setTab(V3KnowledgeLibraryTab value) {
    if (_tab == value) return;
    _tab = value;
    _changed();
  }

  void setSourceCategory(
    V3KnowledgeLibraryTab tab,
    KnowledgeSourceCategory value,
  ) {
    if (tab != V3KnowledgeLibraryTab.mine || sourceCategoryFor(tab) == value) {
      return;
    }
    _sourceCategories[tab] = value;
    _changed();
  }

  void setDepositSourceCategory(KnowledgeSourceCategory value) {
    if (_depositSourceCategory == value) return;
    _depositSourceCategory = value;
    _changed();
  }

  void showDepositFolderBrowser() {
    if (_depositFilterKind == V3DepositFilterKind.browse &&
        _depositFolderFilterId == null) {
      return;
    }
    _depositFilterKind = V3DepositFilterKind.browse;
    _depositFolderFilterId = null;
    _changed();
  }

  void setDepositFolderFilter(String? folderId) {
    final normalized = folderId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next != null && !_folderExists(next)) return;
    if (_depositFilterKind == V3DepositFilterKind.folder &&
        _depositFolderFilterId == next) {
      return;
    }
    _depositFilterKind = next == null
        ? V3DepositFilterKind.browse
        : V3DepositFilterKind.folder;
    _depositFolderFilterId = next;
    _changed();
  }

  void showUnclassifiedDeposits() {
    if (_depositFilterKind == V3DepositFilterKind.unclassified) return;
    _depositFilterKind = V3DepositFilterKind.unclassified;
    _depositFolderFilterId = null;
    _changed();
  }

  void showAllDeposits() {
    if (_depositFilterKind == V3DepositFilterKind.all &&
        _depositFolderFilterId == null) {
      return;
    }
    _depositFilterKind = V3DepositFilterKind.all;
    _depositFolderFilterId = null;
    _changed();
  }

  void setGrouping(V3KnowledgeGrouping value) {
    if (_grouping == value) return;
    _grouping = value;
    _changed();
  }

  void setSourceFilter(KnowledgeSourceFilter value) {
    if (_sourceFilter == value) return;
    _sourceFilter = value;
    _changed();
  }

  void setTimeFilter(KnowledgeTimeFilter value) {
    if (value == KnowledgeTimeFilter.custom && _customTimeRange == null) return;
    if (_timeFilter == value) return;
    _timeFilter = value;
    _changed();
  }

  void setCustomTimeRange(KnowledgeDateRange value) {
    _customTimeRange = _normalizedRange(value);
    _timeFilter = KnowledgeTimeFilter.custom;
    _changed();
  }

  void setSort(V3KnowledgeSort value) {
    if (_sort == value) return;
    _sort = value;
    _changed();
  }

  void setQuery(String value) {
    final normalized = value.trim();
    if (_query == normalized) return;
    _query = normalized;
    _changed();
  }

  void setDepositGrouping(V3KnowledgeGrouping value) {
    if (_depositGrouping == value) return;
    _depositGrouping = value;
    _changed();
  }

  void setDepositSourceFilter(KnowledgeSourceFilter value) {
    if (_depositSourceFilter == value) return;
    _depositSourceFilter = value;
    _changed();
  }

  void setDepositTimeFilter(KnowledgeTimeFilter value) {
    if (value == KnowledgeTimeFilter.custom &&
        _depositCustomTimeRange == null) {
      return;
    }
    if (_depositTimeFilter == value) return;
    _depositTimeFilter = value;
    _changed();
  }

  void setDepositCustomTimeRange(KnowledgeDateRange value) {
    _depositCustomTimeRange = _normalizedRange(value);
    _depositTimeFilter = KnowledgeTimeFilter.custom;
    _changed();
  }

  void setDepositSort(V3KnowledgeSort value) {
    if (_depositSort == value) return;
    _depositSort = value;
    _changed();
  }

  void setDepositQuery(String value) {
    final normalized = value.trim();
    if (_depositQuery == normalized) return;
    _depositQuery = normalized;
    _changed();
  }

  List<V3FeedItem> filteredNotesFor(
    V3KnowledgeLibraryTab tab, {
    String? queryOverride,
  }) {
    final query = (queryOverride ?? _query).trim().toLowerCase();
    final memoKey = (_revision, tab, query);
    if (_filteredNotesMemoKey == memoKey && _filteredNotesMemo != null) {
      return _filteredNotesMemo!;
    }
    final sourceCategory = sourceCategoryFor(tab);
    final result = _notes().where((note) {
      final inActiveTab = switch (tab) {
        V3KnowledgeLibraryTab.mine => note.ownership == V3NoteOwnership.mine,
        V3KnowledgeLibraryTab.subscribed => _hasMembership(
          note.id,
          V3LibraryCollection.subscribed,
        ),
        V3KnowledgeLibraryTab.square => _hasMembership(
          note.id,
          V3LibraryCollection.square,
        ),
      };
      if (!inActiveTab || !sourceCategory.includes(note.source)) return false;
      if (tab == V3KnowledgeLibraryTab.mine &&
          (!_sourceFilter.includes(note.source) ||
              !_includesUpdatedAt(
                note.updatedAt,
                filter: _timeFilter,
                customRange: _customTimeRange,
              ))) {
        return false;
      }
      return _matchesQuery(note, query);
    }).toList();
    result.sort((left, right) => _compareNotes(left, right, _sort));
    final immutable = List<V3FeedItem>.unmodifiable(result);
    _filteredNotesMemoKey = memoKey;
    _filteredNotesMemo = immutable;
    return immutable;
  }

  List<V3FeedItem> get filteredDepositNotes {
    if (_filteredDepositNotesMemoRevision == _revision &&
        _filteredDepositNotesMemo != null) {
      return _filteredDepositNotesMemo!;
    }
    final query = _depositQuery.toLowerCase();
    final result = _notes().where(
      (note) {
        if (!_isDeposited(note) ||
            !_depositSourceCategory.includes(note.source) ||
            !_depositSourceFilter.includes(note.source) ||
            !_includesUpdatedAt(
              note.updatedAt,
              filter: _depositTimeFilter,
              customRange: _depositCustomTimeRange,
            )) {
          return false;
        }
        final folderId = _folderIdFor(note.id);
        if (query.isEmpty &&
            _depositFilterKind == V3DepositFilterKind.unclassified &&
            folderId != null) {
          return false;
        }
        if (query.isEmpty &&
            _depositFilterKind == V3DepositFilterKind.folder &&
            folderId != _depositFolderFilterId) {
          return false;
        }
        return _matchesQuery(note, query);
      },
    ).toList()..sort((left, right) => _compareNotes(left, right, _depositSort));
    final immutable = List<V3FeedItem>.unmodifiable(result);
    _filteredDepositNotesMemoRevision = _revision;
    _filteredDepositNotesMemo = immutable;
    return immutable;
  }

  Map<String, List<V3FeedItem>> groupedNotesFor(V3KnowledgeLibraryTab tab) =>
      _groupNotes(filteredNotesFor(tab), grouping: _grouping);

  Map<String, List<V3FeedItem>> get groupedDepositNotes =>
      _groupNotes(filteredDepositNotes, grouping: _depositGrouping);

  void _changed() {
    invalidate();
    notifyListeners();
  }

  bool _matchesQuery(V3FeedItem note, String query) {
    if (query.isEmpty) return true;
    return <String?>[
      note.title,
      note.rawBody,
      note.summaryBody,
      note.source.label,
      note.contentLineName,
      _folderNameFor(note.id),
      ..._effectiveTags(note),
    ].whereType<String>().any((value) => value.toLowerCase().contains(query));
  }

  Map<String, List<V3FeedItem>> _groupNotes(
    Iterable<V3FeedItem> notes, {
    required V3KnowledgeGrouping grouping,
  }) {
    final result = <String, List<V3FeedItem>>{};
    for (final note in notes) {
      result
          .putIfAbsent(_groupLabel(note, grouping), () => <V3FeedItem>[])
          .add(note);
    }
    final entries = result.entries.toList()
      ..sort(
        (left, right) => _groupOrder(
          left.key,
          grouping,
        ).compareTo(_groupOrder(right.key, grouping)),
      );
    return Map<String, List<V3FeedItem>>.unmodifiable(
      <String, List<V3FeedItem>>{
        for (final entry in entries)
          entry.key: List<V3FeedItem>.unmodifiable(entry.value),
      },
    );
  }

  String _groupLabel(V3FeedItem note, V3KnowledgeGrouping grouping) =>
      switch (grouping) {
        V3KnowledgeGrouping.source => _sourceGroupLabel(note.source),
        V3KnowledgeGrouping.contentLine =>
          note.contentLineName?.trim().isNotEmpty == true
              ? note.contentLineName!.trim()
              : '未分类内容',
        V3KnowledgeGrouping.folder => _folderNameFor(note.id) ?? '未归档',
        V3KnowledgeGrouping.ownership => note.ownership.label,
      };

  int _groupOrder(String label, V3KnowledgeGrouping grouping) {
    if (grouping == V3KnowledgeGrouping.folder) {
      final folders = _folderNames();
      final index = folders.indexOf(label);
      if (index != -1) return index;
      if (label == '未归档') return folders.length;
      return folders.length + 1 + label.hashCode.abs();
    }
    final ordered = switch (grouping) {
      V3KnowledgeGrouping.source => const <String>[
        '会议',
        '内录',
        '链接',
        '独白',
        '手写笔记',
        '录音卡',
        '导入资料',
        '热点',
        '其他',
      ],
      V3KnowledgeGrouping.contentLine => const <String>['未分类内容'],
      V3KnowledgeGrouping.folder => const <String>[],
      V3KnowledgeGrouping.ownership => const <String>[
        '我的内容',
        '已订阅',
        '知识世界',
        '热点',
      ],
    };
    final index = ordered.indexOf(label);
    return index == -1 ? ordered.length + label.hashCode.abs() : index;
  }

  int _compareNotes(V3FeedItem left, V3FeedItem right, V3KnowledgeSort sort) =>
      switch (sort) {
        V3KnowledgeSort.recentlyUpdated => right.updatedAt.compareTo(
          left.updatedAt,
        ),
        V3KnowledgeSort.earliestCreated => left.createdAt.compareTo(
          right.createdAt,
        ),
        V3KnowledgeSort.name => left.title.compareTo(right.title),
      };

  bool _includesUpdatedAt(
    DateTime value, {
    required KnowledgeTimeFilter filter,
    required KnowledgeDateRange? customRange,
  }) {
    if (filter == KnowledgeTimeFilter.all) return true;
    final day = _startOfLocalDay(value);
    final now = _startOfLocalDay(_now());
    final (start, endExclusive) = switch (filter) {
      KnowledgeTimeFilter.all => (day, _offsetLocalDay(day, 1)),
      KnowledgeTimeFilter.today => (now, _offsetLocalDay(now, 1)),
      KnowledgeTimeFilter.last7Days => (
        _offsetLocalDay(now, -6),
        _offsetLocalDay(now, 1),
      ),
      KnowledgeTimeFilter.last30Days => (
        _offsetLocalDay(now, -29),
        _offsetLocalDay(now, 1),
      ),
      KnowledgeTimeFilter.thisYear => (
        DateTime(now.year),
        DateTime(now.year + 1),
      ),
      KnowledgeTimeFilter.custom => switch (customRange) {
        KnowledgeDateRange range => (
          _startOfLocalDay(range.start),
          _offsetLocalDay(_startOfLocalDay(range.end), 1),
        ),
        null => (day, day),
      },
    };
    return !day.isBefore(start) && day.isBefore(endExclusive);
  }

  KnowledgeDateRange _normalizedRange(KnowledgeDateRange value) {
    final first = _startOfLocalDay(value.start);
    final second = _startOfLocalDay(value.end);
    return first.isAfter(second)
        ? KnowledgeDateRange(start: second, end: first)
        : KnowledgeDateRange(start: first, end: second);
  }
}

DateTime _startOfLocalDay(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

DateTime _offsetLocalDay(DateTime day, int offset) =>
    DateTime(day.year, day.month, day.day + offset);

String _sourceGroupLabel(V3MaterialSource source) => switch (source) {
  V3MaterialSource.meeting => '会议',
  V3MaterialSource.internalRecording => '内录',
  V3MaterialSource.link => '链接',
  V3MaterialSource.monologue => '独白',
  V3MaterialSource.note => '手写笔记',
  V3MaterialSource.recordingCard => '录音卡',
  V3MaterialSource.documentImport || V3MaterialSource.mediaImport => '导入资料',
  V3MaterialSource.hotspot => '热点',
  _ => '其他',
};
