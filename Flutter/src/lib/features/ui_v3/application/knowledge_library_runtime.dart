import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/knowledge_library_cache.dart';
import '../data/knowledge_user_metadata_repository.dart';
import '../data/v3_deposit_repository.dart';
import '../domain/feed_item_models.dart';
import 'knowledge_note_port.dart';
import 'subscription_port.dart';
import 'workspace_folder_port.dart';

// resident-provider: Shares one mobile subscription port identity for the full account session.
final mobileSubscriptionPortProvider = Provider<MobileSubscriptionPort>((ref) {
  return const DemoMobileSubscriptionPort();
});

// resident-provider: Shares one authenticated Knowledge note port identity for the full account session.
final knowledgeNotePortProvider = Provider<KnowledgeNotePort>((ref) {
  return const UnavailableKnowledgeNotePort();
});

// resident-provider: Shares one account-scoped deposit repository identity across dependent controllers.
final knowledgeDepositRepositoryProvider = Provider<V3DepositRepository?>(
  (ref) => null,
);

// resident-provider: Shares one Workspace folder command port identity for the full account session.
final workspaceFolderPortProvider = Provider<WorkspaceFolderPort>((ref) {
  return const UnavailableWorkspaceFolderPort();
});

// resident-provider: Shares one account-scoped Knowledge metadata repository across dependent controllers.
final knowledgeUserMetadataRepositoryProvider =
    Provider<KnowledgeUserMetadataRepository?>((ref) => null);

// resident-provider: Preserves one account recycle-bin repository identity across route transitions.
final knowledgeTrashRepositoryProvider = Provider<KnowledgeTrashRepository>((
  ref,
) {
  return ApplicationSupportKnowledgeTrashRepository(
    scopeId: ref.watch(knowledgeLibraryCacheScopeProvider),
  );
});

@immutable
final class KnowledgeNoteIndexSnapshot {
  KnowledgeNoteIndexSnapshot({
    required Iterable<String> ids,
    required this.revision,
  }) : ids = List<String>.unmodifiable(ids);

  final List<String> ids;
  final int revision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KnowledgeNoteIndexSnapshot && revision == other.revision;

  @override
  int get hashCode => revision;
}

enum KnowledgeGraphSourceState { loading, ready, failure }

final class KnowledgeGraphReadModel extends ChangeNotifier {
  KnowledgeGraphReadModel(
    Iterable<V3FeedItem> notes, {
    KnowledgeGraphSourceState sourceState = KnowledgeGraphSourceState.ready,
    String? sourceErrorCode,
  }) : _notes = List<V3FeedItem>.unmodifiable(notes),
       // ignore: prefer_initializing_formals
       _sourceState = sourceState,
       // ignore: prefer_initializing_formals
       _sourceErrorCode = sourceErrorCode;

  List<V3FeedItem> _notes;
  KnowledgeGraphSourceState _sourceState;
  String? _sourceErrorCode;
  int _revision = 0;

  List<V3FeedItem> get notes => _notes;
  KnowledgeGraphSourceState get sourceState => _sourceState;
  String? get sourceErrorCode => _sourceErrorCode;
  int get revision => _revision;

  void replaceDepositedNotes(
    Iterable<V3FeedItem> notes, {
    KnowledgeGraphSourceState? sourceState,
    String? sourceErrorCode,
  }) {
    final next = List<V3FeedItem>.of(notes, growable: false);
    final nextSourceState = sourceState ?? _sourceState;
    final nextErrorCode = nextSourceState == KnowledgeGraphSourceState.failure
        ? sourceState == null
              ? _sourceErrorCode
              : sourceErrorCode
        : null;
    if (sameKnowledgeNoteIdentities(_notes, next) &&
        _sourceState == nextSourceState &&
        _sourceErrorCode == nextErrorCode) {
      return;
    }
    _notes = List<V3FeedItem>.unmodifiable(next);
    _sourceState = nextSourceState;
    _sourceErrorCode = nextErrorCode;
    _revision += 1;
    notifyListeners();
  }
}

bool sameKnowledgeNoteIdentities(
  List<V3FeedItem> left,
  List<V3FeedItem> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

// resident-provider: Keeps the account Knowledge cache scope value consistent across sibling routes.
final knowledgeLibraryCacheScopeProvider = Provider<String>((ref) => 'local');

// resident-provider: Keeps the Knowledge fixture policy value consistent across sibling route consumers.
final knowledgeLibraryDemoFixturesEnabledProvider = Provider<bool>(
  (ref) => true,
);

// resident-provider: Keeps the account Knowledge auto-sync policy stable across route transitions.
final knowledgeLibraryAutoSyncOwnedChangesProvider = Provider<bool>(
  (ref) => false,
);

// resident-provider: Shares one remote-cache TTL policy resolver for the full account session.
final knowledgeLibraryRemoteCacheTtlProvider = Provider<Duration Function()>(
  (ref) =>
      () => const Duration(seconds: 300),
);
