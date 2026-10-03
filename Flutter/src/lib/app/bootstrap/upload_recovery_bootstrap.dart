import 'dart:async';

import '../../core/auth/session_store.dart';
import 'app_bootstrap_controller.dart';

typedef UploadRecoveryRunner = Future<void> Function();

/// Starts persisted upload recovery only after authenticated app bootstrap.
final class UploadRecoveryBootstrap {
  UploadRecoveryBootstrap({
    required AppBootstrapController bootstrapController,
    required SessionStore sessionStore,
    required UploadRecoveryRunner recoverDrafts,
  }) : _bootstrapController = bootstrapController,
       _sessionStore = sessionStore,
       _recoverDrafts = recoverDrafts;

  final AppBootstrapController _bootstrapController;
  final SessionStore _sessionStore;
  final UploadRecoveryRunner _recoverDrafts;
  String? _recoveredScope;
  bool _started = false;
  bool _recovering = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _bootstrapController.addListener(_onStateChanged);
    _sessionStore.addListener(_onStateChanged);
    _onStateChanged();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _bootstrapController.removeListener(_onStateChanged);
      _sessionStore.removeListener(_onStateChanged);
    }
  }

  void _onStateChanged() {
    if (_disposed || !_started) return;
    if (_bootstrapController.state.status != AppBootstrapStatus.ready) return;

    final session = _sessionStore.state;
    if (session.authState != SessionAuthState.authenticated) {
      _recoveredScope = null;
      return;
    }
    final scope = _readyRecoveryScope(session);
    if (scope == null || _recovering || _recoveredScope == scope) return;

    _recovering = true;
    unawaited(_runRecovery(scope));
  }

  Future<void> _runRecovery(String scope) async {
    var succeeded = false;
    try {
      await _recoverDrafts();
      succeeded = true;
    } catch (_) {
      // The upload controller retains its failure state and draft for retry.
    } finally {
      if (succeeded && _readyRecoveryScope(_sessionStore.state) == scope) {
        _recoveredScope = scope;
      }
      _recovering = false;
      if (!_disposed && _readyRecoveryScope(_sessionStore.state) != scope) {
        _onStateChanged();
      }
    }
  }
}

String? _readyRecoveryScope(SessionState session) {
  if (session.authState != SessionAuthState.authenticated ||
      session.workspaceStatus != SessionWorkspaceStatus.ready ||
      session.workspace?.status != SessionWorkspaceStatus.ready) {
    return null;
  }
  final userId = session.user?.userId;
  final workspaceId = session.workspace?.workspaceId;
  if (userId == null ||
      workspaceId == null ||
      !_isSafeScopeId(userId) ||
      !_isSafeScopeId(workspaceId)) {
    return null;
  }
  return '$userId\n$workspaceId';
}

bool _isSafeScopeId(String value) {
  return RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(value);
}
