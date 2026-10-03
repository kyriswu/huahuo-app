import 'package:flutter/foundation.dart';

import '../api/api_envelope.dart';
import 'secure_token_store.dart';

enum SessionAuthState { anonymous, authenticated, expired }

enum SessionWorkspaceStatus { ready, creating, syncFailed }

enum SessionPositioningStatus { notStarted, inProgress, completed }

enum SessionRouteType { auth, onboarding, workspaceRetry, v3 }

const localNumericAuthTokens = AuthTokens(
  accessToken: 'huahuo-local-numeric-access-v1',
  refreshToken: 'huahuo-local-numeric-refresh-v1',
);

bool isLocalNumericAuthTokens(AuthTokens tokens) {
  return tokens.accessToken == localNumericAuthTokens.accessToken &&
      tokens.refreshToken == localNumericAuthTokens.refreshToken;
}

SessionUserStatus localNumericAuthUserStatus() {
  return const SessionUserStatus(
    user: SessionUser(
      userId: 'local-numeric-user',
      maskedPhoneNumber: '***',
      displayName: '老周不劝你',
    ),
    workspace: SessionWorkspace(
      status: SessionWorkspaceStatus.ready,
      workspaceId: 'local-numeric-workspace',
    ),
    defaultContentLine: SessionContentLine(
      contentLineId: 'local-numeric-content-line',
      name: '我的内容',
      isPlaceholder: false,
    ),
    onboardingRequired: false,
  );
}

SafeAuthSessionSnapshot localNumericAuthSessionSnapshot(DateTime now) {
  final status = localNumericAuthUserStatus();
  return SafeAuthSessionSnapshot(
    user: status.user,
    expiresAt: now.add(const Duration(days: 3650)),
    workspaceStatus: status.workspace.status,
    onboardingRequired: false,
    defaultContentLine: status.defaultContentLine,
  );
}

final class SessionUser {
  const SessionUser({
    required this.userId,
    required this.maskedPhoneNumber,
    this.displayName,
  });

  final String userId;
  final String maskedPhoneNumber;
  final String? displayName;
}

final class SessionWorkspace {
  const SessionWorkspace({
    required this.status,
    this.workspaceId,
    this.defaultContentLineId,
    this.lastSyncedAt,
  });

  final SessionWorkspaceStatus status;
  final String? workspaceId;
  final String? defaultContentLineId;
  final DateTime? lastSyncedAt;
}

final class SessionContentLine {
  const SessionContentLine({
    required this.contentLineId,
    required this.name,
    this.isPlaceholder,
  });

  final String contentLineId;
  final String name;
  final bool? isPlaceholder;
}

final class SessionReturnTarget {
  const SessionReturnTarget({required this.type, this.id});

  final String type;
  final String? id;
}

final class SessionRecoveryHints {
  const SessionRecoveryHints({
    this.hasUploadRecoveryDrafts = false,
    this.hasPendingAuthenticatedTasks = false,
  });

  final bool hasUploadRecoveryDrafts;
  final bool hasPendingAuthenticatedTasks;
}

final class SessionPositioningProgress {
  const SessionPositioningProgress({
    this.coldStartPercent,
    this.coldStartCompleted,
    this.completedPercent,
  });

  final int? coldStartPercent;
  final bool? coldStartCompleted;
  final int? completedPercent;
}

final class SafeAuthSessionSnapshot {
  const SafeAuthSessionSnapshot({
    required this.user,
    required this.expiresAt,
    required this.workspaceStatus,
    this.onboardingRequired = false,
    this.basicPositioningCompleted,
    this.positioningStatus,
    this.positioningProgress,
    this.needsWorkspaceRetry = false,
    this.defaultContentLine,
  });

  final SessionUser user;
  final DateTime expiresAt;
  final SessionWorkspaceStatus workspaceStatus;
  final bool onboardingRequired;
  final bool? basicPositioningCompleted;
  final SessionPositioningStatus? positioningStatus;
  final SessionPositioningProgress? positioningProgress;
  final bool needsWorkspaceRetry;
  final SessionContentLine? defaultContentLine;
}

final class SessionUserStatus {
  const SessionUserStatus({
    required this.user,
    required this.workspace,
    this.defaultContentLine,
    this.onboardingRequired,
    this.basicPositioningCompleted,
    this.positioningStatus,
    this.positioningProgress,
    this.runningTaskCount = 0,
    this.timeZone,
  });

  final SessionUser user;
  final SessionWorkspace workspace;
  final SessionContentLine? defaultContentLine;
  final bool? onboardingRequired;
  final bool? basicPositioningCompleted;
  final SessionPositioningStatus? positioningStatus;
  final SessionPositioningProgress? positioningProgress;
  final int runningTaskCount;
  final String? timeZone;
}

final class SessionState {
  const SessionState({
    required this.authState,
    required this.onboardingRequired,
    required this.needsWorkspaceRetry,
    required this.runningTaskCount,
    required this.recoveryHints,
    this.firstLoginThisSession = false,
    this.onboardingDecisionIsAuthoritative = false,
    this.basicPositioningCompleted,
    this.positioningStatus,
    this.positioningProgress,
    this.user,
    this.expiresAt,
    this.workspaceStatus,
    this.workspace,
    this.defaultContentLine,
    this.returnTarget,
    this.lastAuthErrorCode,
    this.updatedAt,
  });

  factory SessionState.anonymous({
    SessionRecoveryHints recoveryHints = const SessionRecoveryHints(),
    SessionReturnTarget? returnTarget,
    DateTime? updatedAt,
  }) {
    return SessionState(
      authState: SessionAuthState.anonymous,
      onboardingRequired: false,
      needsWorkspaceRetry: false,
      runningTaskCount: 0,
      recoveryHints: recoveryHints,
      returnTarget: _safeReturnTarget(returnTarget),
      updatedAt: updatedAt,
    );
  }

  final SessionAuthState authState;
  final SessionUser? user;
  final DateTime? expiresAt;
  final bool firstLoginThisSession;
  final bool onboardingRequired;
  final bool onboardingDecisionIsAuthoritative;
  final bool? basicPositioningCompleted;
  final SessionPositioningStatus? positioningStatus;
  final SessionPositioningProgress? positioningProgress;
  final SessionWorkspaceStatus? workspaceStatus;
  final SessionWorkspace? workspace;
  final SessionContentLine? defaultContentLine;
  final bool needsWorkspaceRetry;
  final int runningTaskCount;
  final SessionRecoveryHints recoveryHints;
  final SessionReturnTarget? returnTarget;
  final String? lastAuthErrorCode;
  final DateTime? updatedAt;

  bool get hasConfirmedInitialPositioning =>
      workspaceStatus == SessionWorkspaceStatus.ready &&
      (defaultContentLine?.isPlaceholder == false ||
          workspace?.defaultContentLineId != null);

  bool get hasAuthoritativeInitialPositioningStatus =>
      basicPositioningCompleted != null || positioningStatus != null;

  bool get hasCompletedInitialPositioning =>
      basicPositioningCompleted == true ||
      positioningStatus == SessionPositioningStatus.completed;

  bool get requiresInitialPositioning {
    // The explicit onboarding decision controls whether an existing account
    // must re-enter first-run intake. Positioning progress is supplemental:
    // a stale in-progress receipt must not reopen a server-completed account.
    if (hasCompletedInitialPositioning) return false;
    if (onboardingDecisionIsAuthoritative) return onboardingRequired;
    if (hasConfirmedInitialPositioning) return false;
    if (hasAuthoritativeInitialPositioningStatus) return true;
    return onboardingRequired;
  }

  bool get isFirstLoginSessionEligible =>
      authState == SessionAuthState.authenticated &&
      user != null &&
      firstLoginThisSession;

  bool get requiresFirstLoginOnboarding =>
      isFirstLoginSessionEligible && requiresInitialPositioning;

  SessionState copyWith({
    SessionAuthState? authState,
    Object? user = _unchanged,
    Object? expiresAt = _unchanged,
    bool? firstLoginThisSession,
    bool? onboardingRequired,
    bool? onboardingDecisionIsAuthoritative,
    Object? basicPositioningCompleted = _unchanged,
    Object? positioningStatus = _unchanged,
    Object? positioningProgress = _unchanged,
    Object? workspaceStatus = _unchanged,
    Object? workspace = _unchanged,
    Object? defaultContentLine = _unchanged,
    bool? needsWorkspaceRetry,
    int? runningTaskCount,
    SessionRecoveryHints? recoveryHints,
    Object? returnTarget = _unchanged,
    Object? lastAuthErrorCode = _unchanged,
    DateTime? updatedAt,
  }) {
    return SessionState(
      authState: authState ?? this.authState,
      user: user == _unchanged ? this.user : user as SessionUser?,
      expiresAt: expiresAt == _unchanged
          ? this.expiresAt
          : expiresAt as DateTime?,
      firstLoginThisSession:
          firstLoginThisSession ?? this.firstLoginThisSession,
      onboardingRequired: onboardingRequired ?? this.onboardingRequired,
      onboardingDecisionIsAuthoritative:
          onboardingDecisionIsAuthoritative ??
          this.onboardingDecisionIsAuthoritative,
      basicPositioningCompleted: basicPositioningCompleted == _unchanged
          ? this.basicPositioningCompleted
          : basicPositioningCompleted as bool?,
      positioningStatus: positioningStatus == _unchanged
          ? this.positioningStatus
          : positioningStatus as SessionPositioningStatus?,
      positioningProgress: positioningProgress == _unchanged
          ? this.positioningProgress
          : positioningProgress as SessionPositioningProgress?,
      workspaceStatus: workspaceStatus == _unchanged
          ? this.workspaceStatus
          : workspaceStatus as SessionWorkspaceStatus?,
      workspace: workspace == _unchanged
          ? this.workspace
          : workspace as SessionWorkspace?,
      defaultContentLine: defaultContentLine == _unchanged
          ? this.defaultContentLine
          : defaultContentLine as SessionContentLine?,
      needsWorkspaceRetry: needsWorkspaceRetry ?? this.needsWorkspaceRetry,
      runningTaskCount: runningTaskCount ?? this.runningTaskCount,
      recoveryHints: recoveryHints ?? this.recoveryHints,
      returnTarget: returnTarget == _unchanged
          ? this.returnTarget
          : returnTarget as SessionReturnTarget?,
      lastAuthErrorCode: lastAuthErrorCode == _unchanged
          ? this.lastAuthErrorCode
          : lastAuthErrorCode as String?,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

const _unchanged = Object();

final class SessionRouteDecision {
  const SessionRouteDecision({required this.type, this.returnTarget});

  final SessionRouteType type;
  final SessionReturnTarget? returnTarget;
}

final class SessionCommandResult {
  const SessionCommandResult._({required this.ok, this.error});

  factory SessionCommandResult.success() {
    return const SessionCommandResult._(ok: true);
  }

  factory SessionCommandResult.failure(AppFailure error) {
    return SessionCommandResult._(ok: false, error: error);
  }

  final bool ok;
  final AppFailure? error;
}

final class SessionStore extends ChangeNotifier {
  SessionStore({
    required SecureTokenStore secureTokenStore,
    SessionState? initialState,
  }) : _secureTokenStore = secureTokenStore,
       _state = initialState ?? SessionState.anonymous();

  final SecureTokenStore _secureTokenStore;
  SessionState _state;

  SessionState get state => _state;

  void restoreAnonymous({required DateTime restoredAt}) {
    _state = SessionState.anonymous(
      recoveryHints: _state.recoveryHints,
      returnTarget: _state.returnTarget,
      updatedAt: restoredAt,
    );
    notifyListeners();
  }

  void restoreExpired({
    required String errorCode,
    required DateTime restoredAt,
  }) {
    _state =
        SessionState.anonymous(
          recoveryHints: _state.recoveryHints,
          returnTarget: _state.returnTarget,
          updatedAt: restoredAt,
        ).copyWith(
          authState: SessionAuthState.expired,
          lastAuthErrorCode: _safeAuthErrorCode(errorCode),
        );
    notifyListeners();
  }

  void restoreFromUserStatus({
    required SessionUserStatus status,
    required DateTime restoredAt,
  }) {
    _applyUserStatus(
      status: status,
      updatedAt: restoredAt,
      authState: SessionAuthState.authenticated,
      preserveFirstLoginThisSession: false,
    );
  }

  Future<SessionCommandResult> applyLoginSuccess({
    required AuthTokens tokens,
    required SafeAuthSessionSnapshot snapshot,
    bool firstLoginThisSession = false,
    SessionUserStatus? verifiedStatus,
    required DateTime updatedAt,
  }) async {
    if (!_isSafeSessionSnapshot(snapshot) ||
        (verifiedStatus != null &&
            (!_isSafeUserStatus(verifiedStatus) ||
                verifiedStatus.user.userId != snapshot.user.userId))) {
      return SessionCommandResult.failure(
        const AppFailure(
          code: 'SESSION_UNSAFE_SNAPSHOT',
          category: AppFailureCategory.auth,
          message: 'Session snapshot contains unsupported data',
          userMessageKey: 'auth.error.unsafeSession',
          recoveryActions: <String>['login'],
        ),
      );
    }

    final recoveryHint = _recoveryHintFromSnapshot(snapshot);
    final tokenWrite = await _secureTokenStore.setTokens(
      tokens,
      recoveryHint: recoveryHint,
    );
    if (!tokenWrite.ok) {
      return SessionCommandResult.failure(tokenWrite.error!);
    }

    final status = verifiedStatus;
    _state = status == null
        ? _state.copyWith(
            authState: SessionAuthState.authenticated,
            user: snapshot.user,
            expiresAt: snapshot.expiresAt,
            firstLoginThisSession: firstLoginThisSession,
            onboardingRequired: snapshot.onboardingRequired,
            onboardingDecisionIsAuthoritative: false,
            basicPositioningCompleted: snapshot.basicPositioningCompleted,
            positioningStatus: snapshot.positioningStatus,
            positioningProgress: snapshot.positioningProgress,
            workspaceStatus: snapshot.workspaceStatus,
            workspace: SessionWorkspace(
              status: snapshot.workspaceStatus,
              defaultContentLineId: snapshot.defaultContentLine?.contentLineId,
            ),
            defaultContentLine: snapshot.defaultContentLine,
            needsWorkspaceRetry:
                snapshot.needsWorkspaceRetry ||
                snapshot.workspaceStatus == SessionWorkspaceStatus.syncFailed,
            runningTaskCount: 0,
            lastAuthErrorCode: null,
            updatedAt: updatedAt,
          )
        : _state.copyWith(
            authState: SessionAuthState.authenticated,
            user: status.user,
            expiresAt: snapshot.expiresAt,
            firstLoginThisSession: firstLoginThisSession,
            onboardingRequired: _onboardingRequiredForStatus(
              status,
              fallback: snapshot.onboardingRequired,
            ),
            onboardingDecisionIsAuthoritative:
                status.onboardingRequired != null,
            basicPositioningCompleted:
                status.basicPositioningCompleted ??
                snapshot.basicPositioningCompleted,
            positioningStatus:
                status.positioningStatus ?? snapshot.positioningStatus,
            positioningProgress:
                status.positioningProgress ?? snapshot.positioningProgress,
            workspaceStatus: status.workspace.status,
            workspace: status.workspace,
            defaultContentLine: status.defaultContentLine,
            needsWorkspaceRetry:
                status.workspace.status == SessionWorkspaceStatus.syncFailed,
            runningTaskCount: status.runningTaskCount,
            lastAuthErrorCode: null,
            updatedAt: updatedAt,
          );
    notifyListeners();
    return SessionCommandResult.success();
  }

  void refreshUserStatus({
    required SessionUserStatus status,
    required DateTime updatedAt,
  }) {
    final authState = _state.authState == SessionAuthState.expired
        ? SessionAuthState.expired
        : SessionAuthState.authenticated;
    _applyUserStatus(
      status: status,
      updatedAt: updatedAt,
      authState: authState,
    );
  }

  void requireWorkspaceRecovery({required DateTime updatedAt}) {
    if (_state.authState != SessionAuthState.authenticated) return;
    _state = _state.copyWith(
      workspaceStatus: SessionWorkspaceStatus.creating,
      workspace: const SessionWorkspace(
        status: SessionWorkspaceStatus.creating,
      ),
      needsWorkspaceRetry: true,
      updatedAt: updatedAt,
    );
    notifyListeners();
  }

  bool restoreWorkspaceRecovery({
    required AuthSessionRecoveryHint hint,
    required DateTime restoredAt,
  }) {
    final workspaceStatus = _workspaceStatusFromHint(hint.workspaceStatus);
    final positioningStatus = _positioningStatusFromHint(
      hint.positioningStatus,
    );
    if (workspaceStatus == null || positioningStatus == _invalidPositioning) {
      return false;
    }
    _state = SessionState.anonymous(updatedAt: restoredAt).copyWith(
      authState: SessionAuthState.authenticated,
      user: SessionUser(
        userId: hint.userId,
        maskedPhoneNumber: hint.maskedPhoneNumber,
      ),
      workspaceStatus: workspaceStatus,
      workspace: SessionWorkspace(status: workspaceStatus),
      onboardingRequired: hint.onboardingRequired,
      basicPositioningCompleted: hint.basicPositioningCompleted,
      positioningStatus: positioningStatus,
      positioningProgress: SessionPositioningProgress(
        coldStartPercent: hint.coldStartPercent,
        completedPercent: hint.completedPercent,
      ),
      needsWorkspaceRetry: true,
      updatedAt: restoredAt,
    );
    notifyListeners();
    return true;
  }

  /// The onboarding endpoint is authoritative that the first content line was
  /// created. Only then may the route guard release the authenticated session.
  bool completeOnboarding({
    required SessionContentLine defaultContentLine,
    required DateTime completedAt,
  }) {
    if (_state.authState != SessionAuthState.authenticated ||
        !_state.requiresInitialPositioning ||
        _state.needsWorkspaceRetry ||
        _state.workspaceStatus != SessionWorkspaceStatus.ready ||
        !_isSafeContentLine(defaultContentLine)) {
      return false;
    }
    _state = _state.copyWith(
      onboardingRequired: false,
      onboardingDecisionIsAuthoritative: true,
      basicPositioningCompleted: true,
      positioningStatus: SessionPositioningStatus.completed,
      defaultContentLine: defaultContentLine,
      lastAuthErrorCode: null,
      updatedAt: completedAt,
    );
    notifyListeners();
    return true;
  }

  /// Applies a completed onboarding handoff after the public Run, first
  /// positioning, and local report projection have all succeeded. Unlike
  /// [completeOnboarding], it remains idempotent when a status refresh has
  /// already observed the server-side positioning completion.
  bool applyInitialPositioningFinalization({
    required SessionContentLine defaultContentLine,
    required DateTime completedAt,
  }) {
    if (_state.authState != SessionAuthState.authenticated ||
        _state.needsWorkspaceRetry ||
        _state.workspaceStatus != SessionWorkspaceStatus.ready ||
        !_isSafeContentLine(defaultContentLine)) {
      return false;
    }
    _state = _state.copyWith(
      onboardingRequired: false,
      onboardingDecisionIsAuthoritative: true,
      basicPositioningCompleted: true,
      positioningStatus: SessionPositioningStatus.completed,
      defaultContentLine: defaultContentLine,
      lastAuthErrorCode: null,
      updatedAt: completedAt,
    );
    notifyListeners();
    return true;
  }

  /// Applies a completion verified from the backend initial-positioning
  /// attempt after its report has been durably saved. The backend no longer
  /// creates a default content line as part of this workflow.
  bool applyInitialPositioningAttemptCompletion({
    required DateTime completedAt,
  }) {
    if (_state.authState != SessionAuthState.authenticated ||
        _state.needsWorkspaceRetry ||
        _state.workspaceStatus != SessionWorkspaceStatus.ready) {
      return false;
    }
    _state = _state.copyWith(
      onboardingRequired: false,
      onboardingDecisionIsAuthoritative: true,
      basicPositioningCompleted: true,
      positioningStatus: SessionPositioningStatus.completed,
      lastAuthErrorCode: null,
      updatedAt: completedAt.toUtc(),
    );
    notifyListeners();
    return true;
  }

  void _applyUserStatus({
    required SessionUserStatus status,
    required DateTime updatedAt,
    required SessionAuthState authState,
    bool preserveFirstLoginThisSession = true,
  }) {
    if (!_isSafeUserStatus(status)) {
      return;
    }
    final sameUser = _state.user?.userId == status.user.userId;
    final preserveCompletedPositioning =
        sameUser && _state.hasCompletedInitialPositioning;
    _state = _state.copyWith(
      authState: authState,
      user: status.user,
      firstLoginThisSession: preserveFirstLoginThisSession && sameUser
          ? _state.firstLoginThisSession
          : false,
      workspaceStatus: status.workspace.status,
      workspace: status.workspace,
      defaultContentLine: status.defaultContentLine,
      onboardingRequired: preserveCompletedPositioning
          ? false
          : _onboardingRequiredForStatus(
              status,
              fallback: _state.onboardingRequired,
            ),
      onboardingDecisionIsAuthoritative: preserveCompletedPositioning
          ? true
          : status.onboardingRequired != null
          ? true
          : _state.onboardingDecisionIsAuthoritative,
      basicPositioningCompleted: preserveCompletedPositioning
          ? true
          : status.basicPositioningCompleted ??
                _state.basicPositioningCompleted,
      positioningStatus: preserveCompletedPositioning
          ? SessionPositioningStatus.completed
          : status.positioningStatus ?? _state.positioningStatus,
      positioningProgress:
          status.positioningProgress ?? _state.positioningProgress,
      needsWorkspaceRetry:
          status.workspace.status == SessionWorkspaceStatus.syncFailed,
      runningTaskCount: status.runningTaskCount < 0
          ? 0
          : status.runningTaskCount,
      lastAuthErrorCode: null,
      updatedAt: updatedAt,
    );
    notifyListeners();
  }

  Future<void> handleAuthExpired({
    required AppFailure error,
    SessionReturnTarget? returnTarget,
    required DateTime occurredAt,
  }) async {
    if (!isAuthExpiredFailure(error)) {
      return;
    }
    _state = _state.copyWith(
      returnTarget: returnTarget ?? _state.returnTarget,
      lastAuthErrorCode: _safeAuthErrorCode(error.code),
      updatedAt: occurredAt,
    );
    notifyListeners();
  }

  Future<void> logout({required DateTime loggedOutAt}) async {
    await _secureTokenStore.clearTokens(SecureTokenClearReason.logout);
    _state = SessionState.anonymous(
      recoveryHints: SessionRecoveryHints(
        hasUploadRecoveryDrafts: _state.recoveryHints.hasUploadRecoveryDrafts,
      ),
      updatedAt: loggedOutAt,
    );
    notifyListeners();
  }

  SessionRouteDecision selectRoute() {
    if (_state.authState != SessionAuthState.authenticated) {
      return const SessionRouteDecision(type: SessionRouteType.auth);
    }
    if (_state.needsWorkspaceRetry ||
        _state.workspaceStatus == SessionWorkspaceStatus.syncFailed ||
        _state.workspaceStatus == SessionWorkspaceStatus.creating) {
      return const SessionRouteDecision(type: SessionRouteType.workspaceRetry);
    }
    if (_state.requiresFirstLoginOnboarding) {
      return const SessionRouteDecision(type: SessionRouteType.onboarding);
    }
    return SessionRouteDecision(
      type: SessionRouteType.v3,
      returnTarget: _state.returnTarget,
    );
  }
}

bool _isSafeSessionSnapshot(SafeAuthSessionSnapshot snapshot) {
  return _isSafeUser(snapshot.user) &&
      snapshot.expiresAt.millisecondsSinceEpoch > 0 &&
      (snapshot.defaultContentLine == null ||
          _isSafeContentLine(snapshot.defaultContentLine!));
}

AuthSessionRecoveryHint _recoveryHintFromSnapshot(
  SafeAuthSessionSnapshot snapshot,
) {
  return AuthSessionRecoveryHint(
    userId: snapshot.user.userId,
    maskedPhoneNumber: snapshot.user.maskedPhoneNumber,
    workspaceStatus: _workspaceStatusWire(snapshot.workspaceStatus),
    onboardingRequired: snapshot.onboardingRequired,
    basicPositioningCompleted: snapshot.basicPositioningCompleted,
    positioningStatus: _positioningStatusWire(snapshot.positioningStatus),
    coldStartPercent: snapshot.positioningProgress?.coldStartPercent,
    completedPercent: snapshot.positioningProgress?.completedPercent,
  );
}

String _workspaceStatusWire(SessionWorkspaceStatus status) => switch (status) {
  SessionWorkspaceStatus.ready => 'ready',
  SessionWorkspaceStatus.creating => 'creating',
  SessionWorkspaceStatus.syncFailed => 'sync_failed',
};

SessionWorkspaceStatus? _workspaceStatusFromHint(String value) =>
    switch (value) {
      'ready' => SessionWorkspaceStatus.ready,
      'creating' => SessionWorkspaceStatus.creating,
      'sync_failed' => SessionWorkspaceStatus.syncFailed,
      _ => null,
    };

String? _positioningStatusWire(SessionPositioningStatus? status) =>
    switch (status) {
      SessionPositioningStatus.notStarted => 'not_started',
      SessionPositioningStatus.inProgress => 'in_progress',
      SessionPositioningStatus.completed => 'completed',
      null => null,
    };

const _invalidPositioning = Object();

Object? _positioningStatusFromHint(String? value) => switch (value) {
  null => null,
  'not_started' => SessionPositioningStatus.notStarted,
  'in_progress' => SessionPositioningStatus.inProgress,
  'completed' => SessionPositioningStatus.completed,
  _ => _invalidPositioning,
};

bool _isSafeUserStatus(SessionUserStatus status) {
  return _isSafeUser(status.user) &&
      (status.workspace.workspaceId == null ||
          _isSafeIdentifier(status.workspace.workspaceId!)) &&
      (status.workspace.defaultContentLineId == null ||
          _isSafeIdentifier(status.workspace.defaultContentLineId!)) &&
      (status.defaultContentLine == null ||
          _isSafeContentLine(status.defaultContentLine!)) &&
      status.runningTaskCount >= 0;
}

bool _onboardingRequiredForStatus(
  SessionUserStatus status, {
  required bool fallback,
}) {
  final explicit = status.onboardingRequired;
  if (explicit != null) return explicit;
  final defaultContentLine = status.defaultContentLine;
  if (defaultContentLine == null) return fallback;
  return status.workspace.status == SessionWorkspaceStatus.ready &&
      (defaultContentLine.isPlaceholder ?? false);
}

bool _isSafeUser(SessionUser user) {
  return _isSafeIdentifier(user.userId) &&
      _isMaskedUserReference(user.maskedPhoneNumber) &&
      (user.displayName == null || user.displayName!.trim().isNotEmpty) &&
      !_containsSensitiveValue(user.userId) &&
      !_containsSensitiveValue(user.maskedPhoneNumber) &&
      !_containsSensitiveValue(user.displayName);
}

bool _isSafeContentLine(SessionContentLine contentLine) {
  return _isSafeIdentifier(contentLine.contentLineId) &&
      contentLine.name.trim().isNotEmpty &&
      !_containsSensitiveValue(contentLine.name);
}

SessionReturnTarget? _safeReturnTarget(SessionReturnTarget? target) {
  if (target == null || _containsSensitiveValue(target.type)) {
    return null;
  }
  final id = target.id;
  if (id != null && (!_isSafeIdentifier(id) || _containsSensitiveValue(id))) {
    return null;
  }
  return target;
}

bool _isSafeIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(value) &&
      !_containsSensitiveValue(value);
}

String _safeAuthErrorCode(String code) {
  if (code == 'AUTH_SESSION_EXPIRED' || code == 'TOKEN_EXPIRED') {
    return code;
  }
  return 'AUTH_SESSION_EXPIRED';
}

bool _isMaskedUserReference(String value) {
  final synthetic = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{0,15}\*{3,4}[A-Za-z0-9_-]{1,16}$',
  );
  return RegExp(r'^\d{3}\*{4}\d{4}$').hasMatch(value) ||
      RegExp(r'^[a-f0-9]{4}\*{3}[a-f0-9]{4}$').hasMatch(value) ||
      synthetic.hasMatch(value) ||
      value == '***' ||
      value == 'hash***';
}

bool _containsSensitiveValue(Object? value) {
  if (value == null) {
    return false;
  }
  if (value is String) {
    return _sensitiveValuePatterns.any((pattern) => pattern.hasMatch(value));
  }
  if (value is Iterable) {
    return value.any(_containsSensitiveValue);
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (_sensitiveKeyPatterns.any(
            (pattern) => pattern.hasMatch(entry.key.toString()),
          ) ||
          _containsSensitiveValue(entry.value)) {
        return true;
      }
    }
  }
  return false;
}

final _sensitiveKeyPatterns = <RegExp>[
  RegExp('token', caseSensitive: false),
  RegExp('authorization', caseSensitive: false),
  RegExp('password', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('raw.*phone', caseSensitive: false),
  RegExp('transcript', caseSensitive: false),
  RegExp('chat.*text', caseSensitive: false),
  RegExp('provider.*key', caseSensitive: false),
  RegExp(
    'runtime.*(session|path|key|config|state|log|workspace|id)',
    caseSensitive: false,
  ),
  RegExp('local.*path', caseSensitive: false),
  RegExp('workspace.*path', caseSensitive: false),
  RegExp(r'^path$', caseSensitive: false),
];

final _sensitiveValuePatterns = <RegExp>[
  RegExp('^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('/home/huahuo-runtime/', caseSensitive: false),
  RegExp('/home/data/huahuo/(runtime|workspaces)/', caseSensitive: false),
  RegExp('runtime:tenant:', caseSensitive: false),
  RegExp('openclaw', caseSensitive: false),
  RegExp('^https?://', caseSensitive: false),
  RegExp('access-token', caseSensitive: false),
  RegExp('refresh-token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('HTTP 500'),
  RegExp('Native Module Error'),
  RegExp('GATT_ERROR'),
  RegExp('CRC_FAIL'),
];
