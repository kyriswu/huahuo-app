import 'package:huahuo_api/huahuo_api.dart';

import 'masterpiece_state.dart';

const masterpieceUnlockCount = 100;

enum MasterpieceGenerationStage {
  submitting,
  uncertain,
  running,
  awaitingInput,
  generated,
  publishing,
  accepted,
  failed,
  cancelled,
}

final class MasterpieceSourceHead {
  const MasterpieceSourceHead(this.noteId, this.revisionId);
  final String noteId;
  final String revisionId;
}

final class MasterpieceEligibility {
  MasterpieceEligibility(Iterable<MasterpieceSourceHead> notes)
    : notes = List.unmodifiable(notes);
  final List<MasterpieceSourceHead> notes;
  int get count => notes.length;
}

final class MasterpieceGenerationPreparation {
  const MasterpieceGenerationPreparation(this.profileId, this.sources);
  final String profileId;
  final List<SharedNotePartSourceRef> sources;
}

final class MasterpieceGenerationIntent {
  const MasterpieceGenerationIntent({
    required this.bookId,
    required this.baseBookRevisionId,
    required this.profileId,
    required this.instruction,
    required this.sources,
    required this.sectionKey,
    required this.title,
    required this.requestKey,
    required this.initial,
    this.stage = MasterpieceGenerationStage.submitting,
    this.runId,
    this.markdown,
    this.clarification,
    this.cancelRequested = false,
    this.cancelSent = false,
  });

  final String bookId;
  final String baseBookRevisionId;
  final String profileId;
  final String instruction;
  final List<SharedNotePartSourceRef> sources;
  final String sectionKey;
  final String title;
  final String requestKey;
  final bool initial;
  final MasterpieceGenerationStage stage;
  final String? runId;
  final String? markdown;
  final String? clarification;
  final bool cancelRequested;
  final bool cancelSent;

  String get publicationKey => '$requestKey-publish';
  String get cancellationKey => '$requestKey-cancel';
  bool get canDiscard => const {
    MasterpieceGenerationStage.generated,
    MasterpieceGenerationStage.failed,
    MasterpieceGenerationStage.cancelled,
  }.contains(stage);

  MasterpieceGenerationIntent copyWith({
    MasterpieceGenerationStage? stage,
    String? runId,
    String? markdown,
    String? clarification,
    bool? cancelRequested,
    bool? cancelSent,
  }) => MasterpieceGenerationIntent(
    bookId: bookId,
    baseBookRevisionId: baseBookRevisionId,
    profileId: profileId,
    instruction: instruction,
    sources: sources,
    sectionKey: sectionKey,
    title: title,
    requestKey: requestKey,
    initial: initial,
    stage: stage ?? this.stage,
    runId: runId ?? this.runId,
    markdown: markdown ?? this.markdown,
    clarification: clarification ?? this.clarification,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    cancelSent: cancelSent ?? this.cancelSent,
  );

  Map<String, Object?> toJson() => {
    'bookId': bookId,
    'baseBookRevisionId': baseBookRevisionId,
    'profileId': profileId,
    'instruction': instruction,
    'sources': sources.map((source) => source.toJson()).toList(),
    'sectionKey': sectionKey,
    'title': title,
    'requestKey': requestKey,
    'initial': initial,
    'stage': stage.name,
    'runId': runId,
    'markdown': markdown,
    'clarification': clarification,
    'cancelRequested': cancelRequested,
    'cancelSent': cancelSent,
  };

  factory MasterpieceGenerationIntent.fromJson(Map<String, Object?> json) {
    final intent = MasterpieceGenerationIntent(
      bookId: json['bookId'] as String,
      baseBookRevisionId: json['baseBookRevisionId'] as String,
      profileId: json['profileId'] as String,
      instruction: json['instruction'] as String,
      sources: List.unmodifiable(
        (json['sources'] as List).map(
          (source) => SharedNotePartSourceRef.fromJson(
            Map<String, Object?>.from(source as Map),
          ),
        ),
      ),
      sectionKey: json['sectionKey'] as String,
      title: json['title'] as String,
      requestKey: json['requestKey'] as String,
      initial: json['initial'] as bool,
      stage: MasterpieceGenerationStage.values.byName(json['stage'] as String),
      runId: json['runId'] as String?,
      markdown: json['markdown'] as String?,
      clarification: json['clarification'] as String?,
      cancelRequested: json['cancelRequested'] as bool,
      cancelSent: json['cancelSent'] as bool,
    );
    if ([
          intent.bookId,
          intent.baseBookRevisionId,
          intent.profileId,
          intent.instruction,
          intent.title,
          intent.requestKey,
        ].any((value) => value.trim().isEmpty) ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(intent.sectionKey) ||
        intent.sources.isEmpty ||
        intent.sources.length > masterpieceUnlockCount ||
        intent.sources.map((source) => source.noteId).toSet().length !=
            intent.sources.length ||
        (const {
              MasterpieceGenerationStage.running,
              MasterpieceGenerationStage.awaitingInput,
              MasterpieceGenerationStage.generated,
              MasterpieceGenerationStage.publishing,
              MasterpieceGenerationStage.accepted,
            }.contains(intent.stage) &&
            intent.runId?.isNotEmpty != true) ||
        (const {
              MasterpieceGenerationStage.generated,
              MasterpieceGenerationStage.publishing,
              MasterpieceGenerationStage.accepted,
            }.contains(intent.stage) &&
            intent.markdown?.trim().isNotEmpty != true)) {
      throw const FormatException('Invalid masterpiece generation intent');
    }
    return intent;
  }
}

final class MasterpieceGenerationRecord {
  const MasterpieceGenerationRecord({
    this.unlocked = false,
    this.noteCount = 0,
    this.automaticAttempted = false,
    this.attempt = 0,
    this.settled = false,
    this.published = false,
    this.intent,
  });

  final bool unlocked;
  final int noteCount;
  final bool automaticAttempted;
  final int attempt;
  final bool settled;
  final bool published;
  final MasterpieceGenerationIntent? intent;

  MasterpieceGenerationRecord copyWith({
    bool? unlocked,
    int? noteCount,
    bool? automaticAttempted,
    int? attempt,
    bool? settled,
    bool? published,
    MasterpieceGenerationIntent? intent,
    bool clearIntent = false,
  }) => MasterpieceGenerationRecord(
    unlocked: unlocked ?? this.unlocked,
    noteCount: noteCount ?? this.noteCount,
    automaticAttempted: automaticAttempted ?? this.automaticAttempted,
    attempt: attempt ?? this.attempt,
    settled: settled ?? this.settled,
    published: published ?? this.published,
    intent: clearIntent ? null : intent ?? this.intent,
  );

  Map<String, Object?> toJson() => {
    'schema': 1,
    'unlocked': unlocked,
    'noteCount': noteCount,
    'automaticAttempted': automaticAttempted,
    'attempt': attempt,
    'settled': settled,
    'published': published,
    'intent': intent?.toJson(),
  };

  factory MasterpieceGenerationRecord.fromJson(Map<String, Object?> json) {
    final record = MasterpieceGenerationRecord(
      unlocked: json['unlocked'] as bool,
      noteCount: json['noteCount'] as int,
      automaticAttempted: json['automaticAttempted'] as bool,
      attempt: json['attempt'] as int,
      settled: json['settled'] as bool,
      published: json['published'] as bool? ?? false,
      intent: json['intent'] == null
          ? null
          : MasterpieceGenerationIntent.fromJson(
              Map<String, Object?>.from(json['intent'] as Map),
            ),
    );
    if (json['schema'] != 1 ||
        record.noteCount < 0 ||
        record.attempt < 0 ||
        (record.intent != null &&
            (!record.unlocked || !record.automaticAttempted))) {
      throw const FormatException('Invalid masterpiece unlock record');
    }
    return record;
  }
}

abstract interface class MasterpieceGenerationStore {
  MasterpieceGenerationRecord? read();
  Future<void> write(MasterpieceGenerationRecord record);
}

abstract interface class MasterpieceGenerationRemote {
  Future<MasterpieceEligibility> eligibility();
  Future<MasterpieceGenerationPreparation> prepare(
    MasterpieceEligibility eligibility,
  );
  Future<AgentRunSnapshot> create(MasterpieceGenerationIntent intent);
  Future<AgentRunSnapshot> run(String runId);
  Future<AgentRunSnapshot> cancel(MasterpieceGenerationIntent intent);
  Future<MasterpieceSnapshot> book();
  Future<void> publish(MasterpieceGenerationIntent intent);
  Future<MasterpieceSnapshot?> readback(MasterpieceGenerationIntent intent);
}
