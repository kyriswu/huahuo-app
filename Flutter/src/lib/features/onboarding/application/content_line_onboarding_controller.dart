import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/auth/session_store.dart';
import '../../ui_v3/data/deep_positioning_repository.dart';
import '../../ui_v3/domain/positioning_lifecycle.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../chat/domain/chat_models.dart';
import '../data/initial_positioning_agent.dart';
import '../data/onboarding_api.dart';
import '../data/onboarding_progress_repository.dart';

enum OnboardingIntakeMode { business, noBusiness }

extension OnboardingIntakeModeWire on OnboardingIntakeMode {
  String get wireName => switch (this) {
    OnboardingIntakeMode.business => onboardingBusinessMode,
    OnboardingIntakeMode.noBusiness => onboardingNoBusinessMode,
  };

  String get label => switch (this) {
    OnboardingIntakeMode.business => '有业务',
    OnboardingIntakeMode.noBusiness => '没业务',
  };
}

OnboardingIntakeMode? onboardingModeFromWire(String value) => switch (value) {
  onboardingBusinessMode => OnboardingIntakeMode.business,
  onboardingNoBusinessMode => OnboardingIntakeMode.noBusiness,
  _ => null,
};

enum OnboardingIntakeInput { singleChoice, multiChoice, text }

final class OnboardingIntakeQuestion {
  const OnboardingIntakeQuestion({
    required this.id,
    required this.title,
    required this.input,
    this.detail,
    this.options = const <String>[],
    this.allowCustomAnswer = false,
    this.maximumLength = 240,
  });

  final String id;
  final String title;
  final String? detail;
  final OnboardingIntakeInput input;
  final List<String> options;
  final bool allowCustomAnswer;
  final int maximumLength;
}

const onboardingIntakeQuestions =
    <OnboardingIntakeMode, List<OnboardingIntakeQuestion>>{
      OnboardingIntakeMode.business: <OnboardingIntakeQuestion>[
        OnboardingIntakeQuestion(
          id: 'customerScope',
          title: '你的客户更偏向哪里？',
          input: OnboardingIntakeInput.singleChoice,
          options: <String>['全国客户', '本地客户', '都可以'],
          allowCustomAnswer: true,
          maximumLength: 60,
        ),
        OnboardingIntakeQuestion(
          id: 'productDescription',
          title: '简单描述一下你的产品或服务',
          detail: '可以写你卖什么、怎么交付、价格带、优势或目前最想推的业务。',
          input: OnboardingIntakeInput.text,
        ),
        OnboardingIntakeQuestion(
          id: 'desiredCustomer',
          title: '你最想要怎样的客户？',
          detail: '可以写行业、人群、预算、需求强度、你最愿意服务的客户状态。',
          input: OnboardingIntakeInput.text,
        ),
        OnboardingIntakeQuestion(
          id: 'customerTalkValue',
          title: '你能为客户持续讲什么？',
          detail: '可以多选。',
          input: OnboardingIntakeInput.multiChoice,
          options: <String>['行业信息差', '对客户的问题提出解决办法', '有自己的观点'],
          allowCustomAnswer: true,
          maximumLength: 60,
        ),
      ],
      OnboardingIntakeMode.noBusiness: <OnboardingIntakeQuestion>[
        OnboardingIntakeQuestion(
          id: 'userProfile',
          title: '你是否有明确的用户画像？',
          detail: '有的话直接描述，没有的话可以写没有。',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'direction',
          title: '你是否有想做的方向？',
          detail: '有的话直接描述，没有的话可以写没有。',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'strengths',
          title: '你擅长什么？',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'dailyConcerns',
          title: '你平时都关心什么？',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'readingHabit',
          title: '你平时是否有阅读习惯？',
          detail: '有的话说下最近几年印象深刻的书，没有的话可以写没有。',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'workHistory',
          title: '你之前都做过什么工作？',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
        OnboardingIntakeQuestion(
          id: 'schoolMajor',
          title: '上学期间学过什么专业？',
          input: OnboardingIntakeInput.text,
          maximumLength: 120,
        ),
      ],
    };

enum ContentLineOnboardingStatus {
  editing,
  reportReady,
  submitting,
  completed,
  failed,
}

final class OnboardingPositioningFact {
  const OnboardingPositioningFact({required this.label, required this.value});

  final String label;
  final String value;

  Map<String, String> toJson() => <String, String>{
    'label': label,
    'value': value,
  };
}

/// Local projection of the first-start answers. It intentionally has no API
/// dependency so the App can render the report before its server contract lands.
final class OnboardingPositioningReport {
  const OnboardingPositioningReport({
    required this.mode,
    required this.progressPercent,
    required this.initialJudgement,
    required this.confirmedFacts,
    required this.missingFacts,
    required this.nextQuestion,
    required this.contentGuidance,
  });

  final OnboardingIntakeMode mode;
  final int progressPercent;
  final String initialJudgement;
  final List<OnboardingPositioningFact> confirmedFacts;
  final List<String> missingFacts;
  final String nextQuestion;
  final String contentGuidance;

  Map<String, Object> toJson() => <String, Object>{
    'mode': mode.wireName,
    'progress': <String, Object>{
      'percent': progressPercent,
      'stage': 'initial_positioning_complete',
    },
    'initialJudgement': initialJudgement,
    'confirmedFacts': confirmedFacts
        .map((fact) => fact.toJson())
        .toList(growable: false),
    'missingFacts': missingFacts,
    'nextQuestion': nextQuestion,
    'contentGuidance': contentGuidance,
  };
}

final class ContentLineOnboardingState {
  const ContentLineOnboardingState({
    this.mode,
    this.stepIndex = 0,
    this.answers = const <String, Object>{},
    this.deferredAt,
    this.status = ContentLineOnboardingStatus.editing,
    this.errorCode,
    this.report,
    this.serverReport,
    this.reportThreadId,
    this.positioningReceipt,
    this.confirmedContentLine,
    this.savedProfile,
    this.profileErrorCode,
    this.isRefreshingProfile = false,
  });

  final OnboardingIntakeMode? mode;
  final int stepIndex;
  final Map<String, Object> answers;
  final DateTime? deferredAt;
  final ContentLineOnboardingStatus status;
  final String? errorCode;
  final OnboardingPositioningReport? report;
  final String? serverReport;
  final String? reportThreadId;
  final InitialPositioningRunReceipt? positioningReceipt;
  final OnboardingContentLine? confirmedContentLine;
  final InitialPositioningProfile? savedProfile;
  final String? profileErrorCode;
  final bool isRefreshingProfile;

  bool get isSubmitting => status == ContentLineOnboardingStatus.submitting;
  bool get isDeferred => deferredAt != null;
  bool get isReportReady => status == ContentLineOnboardingStatus.reportReady;
  bool get hasServerReport => serverReport?.trim().isNotEmpty ?? false;
  bool get hasProfileReadFailure => profileErrorCode != null;
  bool get hasSavedProfile => savedProfile != null;

  List<({String profileKind, String markdown})> get savedProfileConclusions {
    final profile = savedProfile;
    if (profile == null) {
      return const <({String profileKind, String markdown})>[];
    }
    return List<({String profileKind, String markdown})>.unmodifiable(
      profile.displayConclusions.map(
        (conclusion) => (
          profileKind: conclusion.profileKind,
          markdown: conclusion.markdown,
        ),
      ),
    );
  }

  List<OnboardingIntakeQuestion> get questions => mode == null
      ? const <OnboardingIntakeQuestion>[]
      : onboardingIntakeQuestions[mode]!;

  OnboardingIntakeQuestion? get currentQuestion =>
      stepIndex >= 0 && stepIndex < questions.length
      ? questions[stepIndex]
      : null;

  bool get canContinue {
    final question = currentQuestion;
    return question != null &&
        isOnboardingAnswerValid(question, answers[question.id]);
  }

  bool get isLastQuestion =>
      currentQuestion != null && stepIndex == questions.length - 1;

  bool get isComplete =>
      mode != null &&
      questions.every(
        (question) => isOnboardingAnswerValid(question, answers[question.id]),
      );

  ContentLineOnboardingState copyWith({
    Object? mode = _unchanged,
    int? stepIndex,
    Map<String, Object>? answers,
    Object? deferredAt = _unchanged,
    ContentLineOnboardingStatus? status,
    Object? errorCode = _unchanged,
    Object? report = _unchanged,
    Object? serverReport = _unchanged,
    Object? reportThreadId = _unchanged,
    Object? positioningReceipt = _unchanged,
    Object? confirmedContentLine = _unchanged,
    Object? savedProfile = _unchanged,
    Object? profileErrorCode = _unchanged,
    bool? isRefreshingProfile,
  }) {
    return ContentLineOnboardingState(
      mode: mode == _unchanged ? this.mode : mode as OnboardingIntakeMode?,
      stepIndex: stepIndex ?? this.stepIndex,
      answers: answers ?? this.answers,
      deferredAt: deferredAt == _unchanged
          ? this.deferredAt
          : deferredAt as DateTime?,
      status: status ?? this.status,
      errorCode: errorCode == _unchanged
          ? this.errorCode
          : errorCode as String?,
      report: report == _unchanged
          ? this.report
          : report as OnboardingPositioningReport?,
      serverReport: serverReport == _unchanged
          ? this.serverReport
          : serverReport as String?,
      reportThreadId: reportThreadId == _unchanged
          ? this.reportThreadId
          : reportThreadId as String?,
      positioningReceipt: positioningReceipt == _unchanged
          ? this.positioningReceipt
          : positioningReceipt as InitialPositioningRunReceipt?,
      confirmedContentLine: confirmedContentLine == _unchanged
          ? this.confirmedContentLine
          : confirmedContentLine as OnboardingContentLine?,
      savedProfile: savedProfile == _unchanged
          ? this.savedProfile
          : savedProfile as InitialPositioningProfile?,
      profileErrorCode: profileErrorCode == _unchanged
          ? this.profileErrorCode
          : profileErrorCode as String?,
      isRefreshingProfile: isRefreshingProfile ?? this.isRefreshingProfile,
    );
  }
}

const _unchanged = Object();

bool isOnboardingAnswerValid(
  OnboardingIntakeQuestion question,
  Object? answer,
) {
  if (answer == null) return false;
  return _normalizeAnswer(question, answer) != null;
}

final class OnboardingContinuationController extends ChangeNotifier {
  OnboardingContinuationController({
    required OnboardingProgressRepository repository,
    DateTime Function()? now,
  }) : _repository = repository,
       _now = now ?? DateTime.now;

  final OnboardingProgressRepository _repository;
  final DateTime Function() _now;

  OnboardingProgressSnapshot snapshotFor(String? userId) {
    if (userId == null) return const OnboardingProgressSnapshot();
    return _repository.load(userId);
  }

  bool isDeferredFor(String? userId) => snapshotFor(userId).isDeferred;

  bool hasAcceptedRunFor(String? userId) =>
      snapshotFor(userId).acceptedRun != null;

  bool hasRegisteredRunFor(String? userId, String? workspaceId) =>
      acceptedRunFor(userId)?.isRegisteredFor(workspaceId) == true;

  bool hasActiveAcceptedRunFor(String? userId) {
    final lifecycle = snapshotFor(userId).acceptedRun?.lifecycle;
    return lifecycle == OnboardingAcceptedRunLifecycle.running ||
        lifecycle == OnboardingAcceptedRunLifecycle.finalizing;
  }

  bool hasFinalizationCheckpointFor(String? userId) {
    return hasActiveAcceptedRunFor(userId);
  }

  OnboardingAcceptedRun? acceptedRunFor(String? userId) =>
      snapshotFor(userId).acceptedRun;

  bool saveDraft(String userId, OnboardingProgressSnapshot snapshot) {
    try {
      final existing = _repository.load(userId);
      final saved = _repository.save(
        userId: userId,
        snapshot: snapshot.copyWith(deferredAt: existing.deferredAt),
        updatedAt: _now().toUtc(),
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  bool defer(String userId, OnboardingProgressSnapshot snapshot) {
    try {
      final saved = _repository.save(
        userId: userId,
        snapshot: snapshot.copyWith(deferredAt: _now().toUtc()),
        updatedAt: _now().toUtc(),
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  bool acceptRun(
    String userId,
    InitialPositioningRunReceipt receipt, {
    String? workspaceId,
  }) {
    final current = snapshotFor(userId);
    final now = _now().toUtc();
    try {
      final saved = _repository.save(
        userId: userId,
        snapshot: current.copyWith(
          acceptedRun: OnboardingAcceptedRun(
            threadId: receipt.threadId,
            agentRunId: receipt.agentRunId,
            taskId: receipt.taskId,
            messageId: receipt.messageId,
            status: receipt.status,
            workspaceId: workspaceId,
            updatedAt: now,
          ),
        ),
        updatedAt: now,
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  bool recordRunRegistration(
    String userId, {
    required String agentRunId,
    required String workspaceId,
    String? attemptId,
    String? errorCode,
  }) {
    final run = acceptedRunFor(userId);
    if (run == null ||
        run.agentRunId != agentRunId ||
        (run.workspaceId != null && run.workspaceId != workspaceId) ||
        !isSafeChatIdentifier(workspaceId) ||
        (errorCode != null &&
            (errorCode.trim().isEmpty || errorCode.length > 160)) ||
        (attemptId != null &&
            !RegExp(
              r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$',
            ).hasMatch(attemptId))) {
      return false;
    }
    if (run.workspaceId == workspaceId &&
        (attemptId == null || run.attemptId == attemptId) &&
        run.registrationErrorCode == errorCode) {
      return true;
    }
    return _updateAcceptedRun(
      userId,
      (current, now) => current.copyWith(
        workspaceId: workspaceId,
        attemptId: attemptId,
        registrationErrorCode: errorCode,
        updatedAt: now,
      ),
    );
  }

  bool markRunFinalizing(String userId) => _updateAcceptedRun(
    userId,
    (run, now) => run.copyWith(
      lifecycle: OnboardingAcceptedRunLifecycle.finalizing,
      failureCode: null,
      reportSource: OnboardingAcceptedRunReportSource.agentReply,
      updatedAt: now,
      completedAt: null,
    ),
  );

  bool markRunSucceeded(
    String userId, {
    OnboardingAcceptedRunReportSource reportSource =
        OnboardingAcceptedRunReportSource.agentReply,
  }) => _updateAcceptedRun(
    userId,
    (run, now) => run.copyWith(
      lifecycle: OnboardingAcceptedRunLifecycle.succeeded,
      failureCode: null,
      reportSource: reportSource,
      updatedAt: now,
      completedAt: now,
    ),
  );

  bool markRunFailed(String userId, String errorCode) {
    final safeCode = errorCode.trim();
    if (safeCode.isEmpty || safeCode.length > 160) return false;
    return _updateAcceptedRun(
      userId,
      (run, now) => run.copyWith(
        lifecycle: OnboardingAcceptedRunLifecycle.failed,
        failureCode: safeCode,
        reportSource: OnboardingAcceptedRunReportSource.agentReply,
        updatedAt: now,
        completedAt: now,
      ),
    );
  }

  bool resetFailedRun(String userId) {
    final snapshot = snapshotFor(userId);
    final run = snapshot.acceptedRun;
    if (run?.lifecycle != OnboardingAcceptedRunLifecycle.failed) return false;
    try {
      final saved = _repository.save(
        userId: userId,
        snapshot: snapshot.copyWith(acceptedRun: null),
        updatedAt: _now().toUtc(),
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  bool acknowledgeSucceededRun(String userId) {
    final snapshot = snapshotFor(userId);
    if (snapshot.acceptedRun?.lifecycle !=
        OnboardingAcceptedRunLifecycle.succeeded) {
      return false;
    }
    try {
      final saved = _repository.save(
        userId: userId,
        snapshot: snapshot.copyWith(acceptedRun: null),
        updatedAt: _now().toUtc(),
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  bool _updateAcceptedRun(
    String userId,
    OnboardingAcceptedRun Function(OnboardingAcceptedRun run, DateTime now)
    update,
  ) {
    final snapshot = snapshotFor(userId);
    final run = snapshot.acceptedRun;
    if (run == null) return false;
    final now = _now().toUtc();
    try {
      final saved = _repository.save(
        userId: userId,
        snapshot: snapshot.copyWith(acceptedRun: update(run, now)),
        updatedAt: now,
      );
      if (saved) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  void complete(String userId) {
    try {
      _repository.clear(userId);
    } catch (_) {}
    notifyListeners();
  }
}

final class ContentLineOnboardingController extends ChangeNotifier {
  ContentLineOnboardingController({
    required OnboardingApiPort api,
    required InitialPositioningAgentPort initialPositioningAgent,
    required SessionStore sessionStore,
    InitialPositioningReportSink? positioningReportSink,
    required OnboardingContinuationController continuation,
    ChatRunTrackingPort? runTracker,
    Future<InitialPositioningAccess> Function()? checkPositioningAccess,
  }) : _api = api,
       // ignore: prefer_initializing_formals
       _initialPositioningAgent = initialPositioningAgent,
       _sessionStore = sessionStore,
       _positioningReportSink = positioningReportSink,
       _continuation = continuation,
       _runTracker = runTracker {
    _checkPositioningAccess = checkPositioningAccess;
    _state = _stateFromSnapshot(
      _continuation.snapshotFor(_sessionStore.state.user?.userId),
    );
    _continuation.addListener(_onContinuationChanged);
  }

  final OnboardingApiPort _api;
  final InitialPositioningAgentPort _initialPositioningAgent;
  final SessionStore _sessionStore;
  final InitialPositioningReportSink? _positioningReportSink;
  final OnboardingContinuationController _continuation;
  final ChatRunTrackingPort? _runTracker;
  SubmissionKeyStore _idempotencyStore = SubmissionKeyStore.empty;
  late ContentLineOnboardingState _state;
  int _draftRevision = 1;
  bool _retrySameDraft = false;
  bool _disposed = false;
  Future<OnboardingContentLine?>? _activeSubmission;
  Future<bool>? _activeWorkspaceEntry;
  Future<InitialPositioningAccess> Function()? _checkPositioningAccess;
  bool _checkingAccess = false;
  InitialPositioningAccess? existingPositioningAccess;

  bool get checkingPositioningAccess => _checkingAccess;

  Future<bool> _canCreatePositioningRun() async {
    if (_checkingAccess || _disposed) return false;
    final check = _checkPositioningAccess;
    if (check == null) return true;
    final revision = _draftRevision;
    final userId = _sessionStore.state.user?.userId;
    final workspaceId = _sessionStore.state.workspace?.workspaceId;
    _checkingAccess = true;
    notifyListeners();
    try {
      final access = await check();
      if (_disposed ||
          revision != _draftRevision ||
          userId != _sessionStore.state.user?.userId ||
          workspaceId != _sessionStore.state.workspace?.workspaceId)
        return false;
      existingPositioningAccess = access;
      return access == InitialPositioningAccess.notStarted ||
          access == InitialPositioningAccess.retryableFailure;
    } catch (_) {
      if (!_disposed)
        existingPositioningAccess = InitialPositioningAccess.unavailable;
      return false;
    } finally {
      _checkingAccess = false;
      if (!_disposed) notifyListeners();
    }
  }

  ContentLineOnboardingState get state => _state;

  OnboardingAcceptedRun? get acceptedRun =>
      _continuation.acceptedRunFor(_sessionStore.state.user?.userId);

  bool get isBackendRegistered =>
      acceptedRun?.isRegisteredFor(
        _sessionStore.state.workspace?.workspaceId,
      ) ==
      true;

  void _onContinuationChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<InitialPositioningRunReceipt?> startBackground() async {
    try {
      if (!_state.isComplete || _state.isSubmitting) return null;
      if (!await _canCreatePositioningRun()) return null;
      final session = _sessionStore.state;
      final userId = session.user?.userId;
      if (userId == null ||
          session.authState != SessionAuthState.authenticated) {
        _fail('ONBOARDING_SESSION_UNAVAILABLE');
        return null;
      }
      final persistedRun = _continuation.acceptedRunFor(userId);
      final existing = _state.positioningReceipt;
      if (persistedRun?.lifecycle == OnboardingAcceptedRunLifecycle.running ||
          persistedRun?.lifecycle ==
              OnboardingAcceptedRunLifecycle.finalizing) {
        return existing;
      }
      if (persistedRun?.lifecycle == OnboardingAcceptedRunLifecycle.failed &&
          !_continuation.resetFailedRun(userId)) {
        _fail('ONBOARDING_PROGRESS_SAVE_FAILED');
        return null;
      }
      final agent = _initialPositioningAgent;
      InitialPositioningRunReceipt? receipt;
      if (agent is! InitialPositioningAgentAcceptedRunPort) {
        _set(
          _state.copyWith(
            status: ContentLineOnboardingStatus.submitting,
            errorCode: null,
          ),
        );
        final result = await agent.submit(
          buildInitialPositioningPrompt(_state),
        );
        if (!result.ok || result.data == null) {
          _fail(result.errorCode ?? 'ONBOARDING_AGENT_SEND_FAILED');
          return null;
        }
        receipt = result.data!.receipt;
      } else {
        final acceptedRunAgent =
            agent as InitialPositioningAgentAcceptedRunPort;
        _set(
          _state.copyWith(
            status: ContentLineOnboardingStatus.submitting,
            errorCode: null,
          ),
        );
        final accepted = await acceptedRunAgent.start(
          buildInitialPositioningPrompt(_state),
        );
        receipt = accepted.receipt;
        if (!accepted.ok || receipt == null) {
          _fail(accepted.errorCode ?? 'ONBOARDING_AGENT_SEND_FAILED');
          return null;
        }
      }
      if (!_continuation.acceptRun(
        userId,
        receipt,
        workspaceId: session.workspace?.workspaceId,
      )) {
        _fail('ONBOARDING_PROGRESS_SAVE_FAILED');
        return null;
      }
      if (!_disposed &&
          _sessionStore.state.user?.userId == userId &&
          _sessionStore.state.workspace?.workspaceId ==
              session.workspace?.workspaceId) {
        unawaited(_trackAcceptedRun(receipt));
      }
      if (_disposed ||
          _sessionStore.state.user?.userId != userId ||
          _sessionStore.state.workspace?.workspaceId !=
              session.workspace?.workspaceId)
        return null;
      _set(
        _state.copyWith(
          status: ContentLineOnboardingStatus.editing,
          positioningReceipt: receipt,
          errorCode: null,
        ),
      );
      return receipt;
    } catch (_) {
      _fail('ONBOARDING_AGENT_SEND_FAILED');
      return null;
    }
  }

  Future<void> _trackAcceptedRun(InitialPositioningRunReceipt receipt) async {
    final tracker = _runTracker;
    if (tracker == null) return;
    try {
      await tracker.track(
        agentRunId: receipt.agentRunId,
        threadId: receipt.threadId,
        scene: ChatScene.workAi,
        purpose: ChatConversationPurpose.deepPositioning,
      );
    } catch (_) {
      // The durable receipt remains recoverable even if foreground tracking
      // starts late; a later bootstrap can attach to the accepted Run.
    }
  }

  void selectMode(OnboardingIntakeMode mode) {
    if (_state.isSubmitting) return;
    _edit(
      ContentLineOnboardingState(mode: mode, deferredAt: _state.deferredAt),
      answerChanged: true,
    );
  }

  void updateAnswer(String questionId, Object answer) {
    if (_state.isSubmitting) return;
    final question = _state.questions
        .where((candidate) => candidate.id == questionId)
        .firstOrNull;
    if (question == null) return;
    final nextAnswers = <String, Object>{..._state.answers};
    final normalized = _normalizeAnswer(question, answer);
    if (normalized == null) {
      nextAnswers.remove(questionId);
    } else {
      nextAnswers[questionId] = normalized;
    }
    _edit(
      _state.copyWith(answers: Map<String, Object>.unmodifiable(nextAnswers)),
      answerChanged: true,
    );
  }

  void goBack() {
    if (_state.isSubmitting || _state.mode == null) return;
    if (_state.stepIndex == 0) {
      _edit(
        ContentLineOnboardingState(deferredAt: _state.deferredAt),
        answerChanged: true,
      );
      return;
    }
    _edit(_state.copyWith(stepIndex: _state.stepIndex - 1));
  }

  void goNext() {
    if (_state.isSubmitting || !_state.canContinue || _state.isLastQuestion) {
      return;
    }
    _edit(_state.copyWith(stepIndex: _state.stepIndex + 1));
  }

  bool defer() {
    final session = _sessionStore.state;
    final userId = session.user?.userId;
    if (session.authState != SessionAuthState.authenticated ||
        !session.requiresInitialPositioning ||
        userId == null) {
      _fail('ONBOARDING_SESSION_UNAVAILABLE');
      return false;
    }
    if (_state.hasServerReport) return false;
    final now = DateTime.now().toUtc();
    // A report request cannot complete onboarding after the user defers it.
    _draftRevision += 1;
    _retrySameDraft = false;
    final saved = _continuation.defer(
      userId,
      _snapshotFromState(_state).copyWith(deferredAt: now),
    );
    if (!saved) {
      _fail('ONBOARDING_PROGRESS_SAVE_FAILED');
      return false;
    }
    _set(
      _state.copyWith(
        deferredAt: now,
        status: ContentLineOnboardingStatus.editing,
        errorCode: null,
      ),
    );
    return true;
  }

  Future<OnboardingContentLine?> submit() {
    final activeSubmission = _activeSubmission;
    if (activeSubmission != null) return activeSubmission;
    final confirmedContentLine = _state.confirmedContentLine;
    if (_state.isReportReady && confirmedContentLine != null) {
      return Future<OnboardingContentLine?>.value(confirmedContentLine);
    }

    final completion = Completer<OnboardingContentLine?>();
    final submission = completion.future;
    _activeSubmission = submission;
    unawaited(_completeSubmission(completion, submission));
    return submission;
  }

  Future<void> _completeSubmission(
    Completer<OnboardingContentLine?> completion,
    Future<OnboardingContentLine?> submission,
  ) async {
    try {
      completion.complete(await _submitOnce());
    } catch (error, stackTrace) {
      completion.completeError(error, stackTrace);
    } finally {
      if (identical(_activeSubmission, submission)) {
        _activeSubmission = null;
      }
    }
  }

  Future<OnboardingContentLine?> _submitOnce() async {
    if (_state.isSubmitting ||
        _state.isReportReady ||
        _state.status == ContentLineOnboardingStatus.completed) {
      return null;
    }
    if (!await _canCreatePositioningRun()) return null;
    final request = buildOnboardingContentLineRequest(_state);
    if (request == null) {
      _fail('ONBOARDING_REQUIRED_FIELDS_INVALID');
      return null;
    }

    final revision = _draftRevision;
    _set(
      _state.copyWith(
        status: ContentLineOnboardingStatus.submitting,
        errorCode: null,
      ),
    );
    var serverReport = _state.serverReport;
    var reportThreadId = _state.reportThreadId;
    var positioningReceipt = _state.positioningReceipt;
    var savedProfile = _state.savedProfile;
    var profileErrorCode = _state.profileErrorCode;
    if (serverReport == null || reportThreadId == null) {
      final agentSubmission = await _initialPositioningAgent.submit(
        buildInitialPositioningPrompt(_state),
      );
      if (_disposed || revision != _draftRevision) return null;
      final agentResult = agentSubmission.data;
      if (!agentSubmission.ok || agentResult == null) {
        _fail(agentSubmission.errorCode ?? 'ONBOARDING_AGENT_SEND_FAILED');
        return null;
      }
      serverReport = agentResult.report;
      reportThreadId = agentResult.threadId;
      positioningReceipt = agentResult.receipt;
      savedProfile = agentResult.savedProfile;
      profileErrorCode = agentResult.profileErrorCode;
      _set(
        _state.copyWith(
          status: ContentLineOnboardingStatus.submitting,
          serverReport: serverReport,
          reportThreadId: reportThreadId,
          positioningReceipt: positioningReceipt,
          savedProfile: savedProfile,
          profileErrorCode: profileErrorCode,
          errorCode: null,
        ),
      );
    }
    final result = await _api.createFirstContentLine(
      request: request,
      idempotency: IdempotencyRequestContext(
        operation: 'onboarding.first_content_line',
        localDraftId: 'first-content-line-$revision',
        scene: 'content_line_onboarding',
        automaticRetry: _retrySameDraft,
      ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    if (_disposed || revision != _draftRevision) return null;

    final response = result.data;
    if (!result.ok || response == null) {
      if (result.error?.code == 'POSITIONING_VERSION_CONFLICT') {
        final existing = await _readExistingDefaultContentLine();
        if (_disposed || revision != _draftRevision) return null;
        if (existing != null) {
          _retrySameDraft = false;
          _set(
            _state.copyWith(
              deferredAt: null,
              status: ContentLineOnboardingStatus.reportReady,
              serverReport: serverReport,
              reportThreadId: reportThreadId,
              positioningReceipt: positioningReceipt,
              confirmedContentLine: existing,
              savedProfile: savedProfile,
              profileErrorCode: profileErrorCode,
              errorCode: null,
            ),
          );
          return existing;
        }
      }
      _retrySameDraft = true;
      _fail(result.error?.code ?? 'ONBOARDING_CONTENT_LINE_CREATE_FAILED');
      return null;
    }
    if (!response.onboardingCompleted ||
        response.contentLine.status != 'active' ||
        !response.contentLine.isDefault ||
        response.contentLine.isPlaceholder) {
      _retrySameDraft = false;
      _fail('ONBOARDING_COMPLETION_INVALID');
      return null;
    }
    _retrySameDraft = false;
    _set(
      _state.copyWith(
        deferredAt: null,
        status: ContentLineOnboardingStatus.reportReady,
        serverReport: serverReport,
        reportThreadId: reportThreadId,
        positioningReceipt: positioningReceipt,
        confirmedContentLine: response.contentLine,
        savedProfile: savedProfile,
        profileErrorCode: profileErrorCode,
        errorCode: null,
      ),
    );
    return response.contentLine;
  }

  Future<OnboardingContentLine?> _readExistingDefaultContentLine() async {
    final api = _api;
    if (api is! OnboardingDefaultContentLineReadPort) return null;
    final reader = api as OnboardingDefaultContentLineReadPort;
    final ApiResult<OnboardingDefaultContentLineRead> result;
    try {
      result = await reader.readDefaultContentLine();
    } catch (_) {
      return null;
    }
    if (!result.ok) return null;
    return result.data?.contentLine;
  }

  Future<bool> enterWorkspace() {
    final activeEntry = _activeWorkspaceEntry;
    if (activeEntry != null) return activeEntry;
    final entry = _enterWorkspace();
    _activeWorkspaceEntry = entry;
    unawaited(
      entry.whenComplete(() {
        if (identical(_activeWorkspaceEntry, entry)) {
          _activeWorkspaceEntry = null;
        }
      }),
    );
    return entry;
  }

  Future<bool> _enterWorkspace() async {
    final contentLine = _state.confirmedContentLine;
    final session = _sessionStore.state;
    final userId = session.user?.userId;
    if (!_state.isReportReady ||
        !_state.hasServerReport ||
        contentLine == null ||
        userId == null ||
        session.authState != SessionAuthState.authenticated) {
      _set(
        _state.copyWith(
          status: ContentLineOnboardingStatus.reportReady,
          errorCode: 'ONBOARDING_SESSION_UNAVAILABLE',
        ),
      );
      return false;
    }

    final reportSink = _positioningReportSink;
    if (reportSink != null) {
      var saved = false;
      try {
        saved = await reportSink.saveInitialReport(
          markdown: _state.serverReport!,
          savedAt: DateTime.now().toUtc(),
        );
      } catch (_) {}
      if (_disposed) return false;
      if (!saved) {
        _set(
          _state.copyWith(
            status: ContentLineOnboardingStatus.reportReady,
            errorCode: 'ONBOARDING_REPORT_SAVE_FAILED',
          ),
        );
        return false;
      }
    }

    final currentSession = _sessionStore.state;
    if (currentSession.authState != SessionAuthState.authenticated ||
        currentSession.user?.userId != userId) {
      _set(
        _state.copyWith(
          status: ContentLineOnboardingStatus.reportReady,
          errorCode: 'ONBOARDING_SESSION_UNAVAILABLE',
        ),
      );
      return false;
    }

    final alreadyApplied =
        !currentSession.requiresInitialPositioning &&
        currentSession.defaultContentLine?.contentLineId ==
            contentLine.contentLineId;
    final applied =
        alreadyApplied ||
        _sessionStore.completeOnboarding(
          defaultContentLine: SessionContentLine(
            contentLineId: contentLine.contentLineId,
            name: contentLine.name,
            isPlaceholder: false,
          ),
          completedAt: DateTime.now().toUtc(),
        );
    if (!applied) {
      _set(
        _state.copyWith(
          status: ContentLineOnboardingStatus.reportReady,
          errorCode: 'ONBOARDING_SESSION_UNAVAILABLE',
        ),
      );
      return false;
    }

    _continuation.complete(userId);
    _set(
      _state.copyWith(
        deferredAt: null,
        status: ContentLineOnboardingStatus.completed,
        errorCode: null,
      ),
    );
    return true;
  }

  Future<void> retrySavedProfile() async {
    if (!_state.hasServerReport || _state.isRefreshingProfile) return;
    _set(_state.copyWith(isRefreshingProfile: true, profileErrorCode: null));
    final result = await _initialPositioningAgent.readSavedProfile();
    if (_disposed) return;
    _set(
      _state.copyWith(
        isRefreshingProfile: false,
        savedProfile: result.profile,
        profileErrorCode: result.errorCode,
      ),
    );
  }

  void _edit(ContentLineOnboardingState next, {bool answerChanged = false}) {
    if (_state.isSubmitting) return;
    if (answerChanged) {
      _draftRevision += 1;
      _retrySameDraft = false;
    }
    final editing = next.copyWith(
      status: ContentLineOnboardingStatus.editing,
      errorCode: null,
      report: null,
      serverReport: null,
      reportThreadId: null,
      positioningReceipt: null,
      confirmedContentLine: null,
      savedProfile: null,
      profileErrorCode: null,
      isRefreshingProfile: false,
    );
    final userId = _sessionStore.state.user?.userId;
    if (userId == null ||
        !_continuation.saveDraft(userId, _snapshotFromState(editing))) {
      _fail('ONBOARDING_PROGRESS_SAVE_FAILED');
      return;
    }
    _set(editing);
  }

  void _fail(String code) {
    _set(
      _state.copyWith(
        status: ContentLineOnboardingStatus.failed,
        errorCode: code,
      ),
    );
  }

  void _set(ContentLineOnboardingState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _continuation.removeListener(_onContinuationChanged);
    super.dispose();
  }
}

String buildInitialPositioningPrompt(ContentLineOnboardingState state) {
  if (!state.isComplete || state.mode == null) {
    throw ArgumentError.value(
      state,
      'state',
      'Onboarding answers are incomplete',
    );
  }
  String answerFor(OnboardingIntakeQuestion question) {
    final answer = state.answers[question.id];
    if (answer is List<String>) return answer.join('、');
    return (answer as String).trim();
  }

  final answerLines = <String>[
    for (final question in state.questions)
      '- ${question.title}：${answerFor(question)}',
  ];
  return <String>[
    '根据下面的新用户启动问卷，填充画像，给出进度，生成一份用户报告。',
    '',
    '用户当前状态：${state.mode!.label}',
    '',
    ...answerLines,
    '',
    '报告请包含：',
    '1. 初步定位判断',
    '2. 已经明确的信息',
    '3. 还缺哪些关键信息',
    '4. 下一步最值得追问的问题',
    '5. 账号内容方向和表达建议',
  ].join('\n');
}

OnboardingPositioningReport buildOnboardingPositioningReport(
  ContentLineOnboardingState state,
) {
  if (!state.isComplete || state.mode == null) {
    throw ArgumentError.value(
      state,
      'state',
      'Onboarding answers are incomplete',
    );
  }
  String answer(String id) => (state.answers[id] as String).trim();
  String answerList(String id) =>
      List<String>.from(state.answers[id]! as List<String>).join('、');
  final questions = state.questions;
  final confirmedFacts = <OnboardingPositioningFact>[
    for (final question in questions)
      OnboardingPositioningFact(
        label: question.title,
        value: question.input == OnboardingIntakeInput.multiChoice
            ? answerList(question.id)
            : answer(question.id),
      ),
  ];

  return switch (state.mode!) {
    OnboardingIntakeMode.business => OnboardingPositioningReport(
      mode: OnboardingIntakeMode.business,
      progressPercent: 78,
      initialJudgement:
          '你已经有可表达的业务基础。先围绕“${answer('productDescription')}”与“${answer('desiredCustomer')}”建立稳定内容主线，再用真实客户反馈收窄定位。',
      confirmedFacts: confirmedFacts,
      missingFacts: const <String>[
        '客户当前最常见、最愿意付费解决的问题',
        '现有产品的交付案例、结果和差异化证据',
        '内容带来咨询或成交的下一步承接方式',
      ],
      nextQuestion: '最近一次客户主动咨询时，他最先提出的问题是什么？',
      contentGuidance:
          '从“${answerList('customerTalkValue')}”中挑一个长期主题，用客户问题、交付过程和结果复盘连续表达；每条内容都明确写给“${answer('desiredCustomer')}”。',
    ),
    OnboardingIntakeMode.noBusiness => OnboardingPositioningReport(
      mode: OnboardingIntakeMode.noBusiness,
      progressPercent: 68,
      initialJudgement:
          '你当前还没有现成业务，但已经给出了“${answer('direction')}”的方向线索。可以从“${answer('strengths')}”和“${answer('dailyConcerns')}”的交集开始，先验证你愿意长期表达的主题。',
      confirmedFacts: confirmedFacts,
      missingFacts: const <String>[
        '最想服务的具体人群正在面对的真实问题',
        '你愿意持续投入三个月验证的一个窄主题',
        '内容获得反馈后，可以提供的第一个轻量帮助或产品',
      ],
      nextQuestion: '在“${answer('dailyConcerns')}”里，哪一个问题你愿意连续观察并分享三个月？',
      contentGuidance:
          '先用“${answer('strengths')}”的经验，围绕“${answer('dailyConcerns')}”做观察、拆解和个人记录；把“${answer('userProfile')}”当作首批读者假设，并根据反馈逐步收窄。',
    ),
  };
}

/// Stable local payload reserved for the later onboarding-report API.
Map<String, Object> buildOnboardingPositioningPayload(
  ContentLineOnboardingState state,
) {
  final report = state.report ?? buildOnboardingPositioningReport(state);
  return <String, Object>{
    'mode': state.mode!.wireName,
    'answers': Map<String, Object>.from(state.answers),
    'report': report.toJson(),
  };
}

CreateFirstContentLineRequest? buildOnboardingContentLineRequest(
  ContentLineOnboardingState state,
) {
  if (!state.isComplete || state.mode == null) return null;
  String text(String id) => (state.answers[id] as String).trim();
  List<String> list(String id) =>
      List<String>.from(state.answers[id]! as List<String>);

  return switch (state.mode!) {
    OnboardingIntakeMode.business => buildCreateFirstContentLineRequest(
      name: text('productDescription'),
      industry: text('customerScope'),
      accountGoal: list('customerTalkValue').join('、'),
      targetAudience: text('desiredCustomer'),
      commonExpressionsText: list('customerTalkValue').join('、'),
    ),
    OnboardingIntakeMode.noBusiness => buildCreateFirstContentLineRequest(
      name: text('direction'),
      industry: text('strengths'),
      accountGoal: <String>[
        '方向：${text('direction')}',
        '平时关注：${text('dailyConcerns')}',
        '阅读习惯：${text('readingHabit')}',
        '工作经历：${text('workHistory')}',
        '专业背景：${text('schoolMajor')}',
      ].join('\n'),
      targetAudience: text('userProfile'),
    ),
  };
}

ContentLineOnboardingState _stateFromSnapshot(
  OnboardingProgressSnapshot snapshot,
) {
  final accepted = snapshot.acceptedRun;
  final failed = accepted?.lifecycle == OnboardingAcceptedRunLifecycle.failed;
  return ContentLineOnboardingState(
    mode: onboardingModeFromWire(snapshot.mode),
    stepIndex: snapshot.stepIndex,
    answers: snapshot.answers,
    deferredAt: snapshot.deferredAt,
    status: failed
        ? ContentLineOnboardingStatus.failed
        : ContentLineOnboardingStatus.editing,
    errorCode: failed ? accepted?.failureCode : null,
    positioningReceipt: accepted == null
        ? null
        : InitialPositioningRunReceipt(
            threadId: accepted.threadId,
            agentRunId: accepted.agentRunId,
            taskId: accepted.taskId,
            messageId: accepted.messageId,
            status: accepted.status,
          ),
  );
}

OnboardingProgressSnapshot _snapshotFromState(
  ContentLineOnboardingState state,
) {
  return OnboardingProgressSnapshot(
    mode: state.mode?.wireName ?? '',
    stepIndex: state.mode == null ? 0 : state.stepIndex,
    answers: state.mode == null ? const <String, Object>{} : state.answers,
    deferredAt: state.deferredAt,
    acceptedRun: state.positioningReceipt == null
        ? null
        : OnboardingAcceptedRun(
            threadId: state.positioningReceipt!.threadId,
            agentRunId: state.positioningReceipt!.agentRunId,
            taskId: state.positioningReceipt!.taskId,
            messageId: state.positioningReceipt!.messageId,
            status: state.positioningReceipt!.status,
          ),
  );
}

Object? _normalizeAnswer(OnboardingIntakeQuestion question, Object answer) {
  if (question.input == OnboardingIntakeInput.multiChoice) {
    if (answer is! List<String>) return null;
    if (answer.length > 8) return null;
    final submitted = <String>[];
    for (final rawValue in answer) {
      final value = _normalizeChoiceAnswer(question, rawValue);
      if (value == null) return null;
      if (!submitted.contains(value)) submitted.add(value);
    }
    final values = <String>[
      for (final option in question.options)
        if (submitted.contains(option)) option,
      for (final value in submitted)
        if (!question.options.contains(value)) value,
    ];
    return values.isEmpty ? null : List<String>.unmodifiable(values);
  }
  if (answer is! String) return null;
  final normalized = answer.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > question.maximumLength) return null;
  if (question.input == OnboardingIntakeInput.singleChoice) {
    return _normalizeChoiceAnswer(question, normalized);
  }
  return normalized;
}

String? _normalizeChoiceAnswer(
  OnboardingIntakeQuestion question,
  String rawValue,
) {
  final value = rawValue.trim();
  if (value.isEmpty || value.length > question.maximumLength) return null;
  if (_containsUnsafeOnboardingText(value)) return null;
  if (question.options.contains(value)) return value;
  return question.allowCustomAnswer ? value : null;
}

bool _containsUnsafeOnboardingText(String value) =>
    value.contains(RegExp(r'[\u0000-\u001F\u007F]'));
