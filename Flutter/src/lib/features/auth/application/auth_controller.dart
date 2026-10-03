import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/auth/session_store.dart';
import '../data/auth_api.dart';

enum AuthSubmissionStatus { idle, sendingCode, loggingIn, committingLogin }

final class AuthControllerState {
  const AuthControllerState({
    this.phone = '',
    this.code = '',
    this.agreementAccepted = false,
    this.smsRequestId,
    this.cooldownUntil,
    this.status = AuthSubmissionStatus.idle,
    this.lastErrorCode,
    this.traceId,
  });

  final String phone;
  final String code;
  final bool agreementAccepted;
  final String? smsRequestId;
  final DateTime? cooldownUntil;
  final AuthSubmissionStatus status;
  final String? lastErrorCode;
  final String? traceId;

  bool get isSendingCode => status == AuthSubmissionStatus.sendingCode;
  bool get isLoggingIn =>
      status == AuthSubmissionStatus.loggingIn ||
      status == AuthSubmissionStatus.committingLogin;
  bool get isCommittingLogin => status == AuthSubmissionStatus.committingLogin;
  bool get phoneValid => validatePhoneNumber(phone);
  bool get codeValid => validateSmsCode(code);

  int cooldownSecondsRemaining(DateTime now) {
    final until = cooldownUntil;
    if (until == null || !until.isAfter(now)) {
      return 0;
    }
    return ((until.difference(now).inMilliseconds + 999) / 1000).floor();
  }

  AuthControllerState copyWith({
    String? phone,
    String? code,
    bool? agreementAccepted,
    Object? smsRequestId = _unchanged,
    Object? cooldownUntil = _unchanged,
    AuthSubmissionStatus? status,
    Object? lastErrorCode = _unchanged,
    Object? traceId = _unchanged,
  }) {
    return AuthControllerState(
      phone: phone ?? this.phone,
      code: code ?? this.code,
      agreementAccepted: agreementAccepted ?? this.agreementAccepted,
      smsRequestId: smsRequestId == _unchanged
          ? this.smsRequestId
          : smsRequestId as String?,
      cooldownUntil: cooldownUntil == _unchanged
          ? this.cooldownUntil
          : cooldownUntil as DateTime?,
      status: status ?? this.status,
      lastErrorCode: lastErrorCode == _unchanged
          ? this.lastErrorCode
          : lastErrorCode as String?,
      traceId: traceId == _unchanged ? this.traceId : traceId as String?,
    );
  }
}

const _unchanged = Object();

final class _LoginDraftSnapshot {
  const _LoginDraftSnapshot({
    required this.phone,
    required this.smsRequestId,
    required this.code,
    required this.agreementAccepted,
  });

  factory _LoginDraftSnapshot.fromState(AuthControllerState state) {
    return _LoginDraftSnapshot(
      phone: state.phone,
      smsRequestId: state.smsRequestId!,
      code: state.code,
      agreementAccepted: state.agreementAccepted,
    );
  }

  final String phone;
  final String smsRequestId;
  final String code;
  final bool agreementAccepted;

  bool matches(AuthControllerState state) {
    return state.phone == phone &&
        state.smsRequestId == smsRequestId &&
        state.code == code &&
        state.agreementAccepted == agreementAccepted;
  }
}

final class AuthController extends ChangeNotifier {
  AuthController({
    required AuthApiPort authApi,
    required SessionStore sessionStore,
    required String deviceId,
    required String clientVersion,
    String userTimeZone = 'UTC',
    bool userTimeZoneIsFallback = false,
    UserTimeZoneApiPort? userTimeZoneApi,
    DateTime Function()? now,
    String Function()? correlationIdFactory,
  }) : _authApi = authApi,
       _sessionStore = sessionStore,
       _deviceId = deviceId,
       _clientVersion = clientVersion,
       _userTimeZone = userTimeZone,
       _userTimeZoneIsFallback = userTimeZoneIsFallback,
       _userTimeZoneApi = userTimeZoneApi,
       _now = now,
       _correlationIdFactory = correlationIdFactory;

  final AuthApiPort _authApi;
  final SessionStore _sessionStore;
  final String _deviceId;
  final String _clientVersion;
  final String _userTimeZone;
  final bool _userTimeZoneIsFallback;
  final UserTimeZoneApiPort? _userTimeZoneApi;
  final DateTime Function()? _now;
  final String Function()? _correlationIdFactory;

  AuthControllerState _state = const AuthControllerState();
  bool _disposed = false;

  AuthControllerState get state => _state;

  @visibleForTesting
  String get configuredDeviceId => _deviceId;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void setPhone(String value) {
    if (_state.isCommittingLogin) {
      _setLoginInProgressError();
      return;
    }
    final phone = value.replaceAll(RegExp(r'\D'), '');
    final normalizedPhone = phone.length > 11 ? phone.substring(0, 11) : phone;
    final changedPhone = normalizedPhone != _state.phone;
    _setState(
      _state.copyWith(
        phone: normalizedPhone,
        smsRequestId: changedPhone ? null : _unchanged,
        cooldownUntil: changedPhone ? null : _unchanged,
        code: changedPhone ? '' : null,
        status: changedPhone && (_state.isSendingCode || _state.isLoggingIn)
            ? AuthSubmissionStatus.idle
            : null,
        lastErrorCode: null,
        traceId: null,
      ),
    );
  }

  void setCode(String value) {
    if (_state.isCommittingLogin) {
      _setLoginInProgressError();
      return;
    }
    final code = value.replaceAll(RegExp(r'\D'), '');
    _setState(
      _state.copyWith(
        code: code.length > 6 ? code.substring(0, 6) : code,
        status: _state.isLoggingIn ? AuthSubmissionStatus.idle : null,
        lastErrorCode: null,
        traceId: null,
      ),
    );
  }

  void setAgreementAccepted(bool accepted) {
    if (_state.isCommittingLogin) {
      _setLoginInProgressError();
      return;
    }
    _setState(
      _state.copyWith(
        agreementAccepted: accepted,
        status: _state.isLoggingIn ? AuthSubmissionStatus.idle : null,
        lastErrorCode: null,
        traceId: null,
      ),
    );
  }

  Future<void> sendSmsCode() async {
    final now = _currentTime();
    if (_state.isSendingCode) {
      _setState(
        _state.copyWith(lastErrorCode: 'AUTH_SMS_IN_PROGRESS', traceId: null),
      );
      return;
    }
    if (_state.isLoggingIn) {
      _setState(
        _state.copyWith(lastErrorCode: 'AUTH_LOGIN_IN_PROGRESS', traceId: null),
      );
      return;
    }
    if (!_state.phoneValid) {
      _setError('AUTH_PHONE_INVALID');
      return;
    }
    if (_state.cooldownSecondsRemaining(now) > 0) {
      _setError('AUTH_SMS_COOLDOWN');
      return;
    }

    final requestPhone = _state.phone;
    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.sendingCode,
        lastErrorCode: null,
        traceId: null,
      ),
    );

    final AuthApiResult<SendSmsCodeResponse> result;
    try {
      result = await _authApi.sendSmsCode(
        phone: requestPhone,
        correlationId: _correlationId('auth-sms-code'),
        idempotency: IdempotencyRequestContext(
          operation: 'auth-sms-code',
          businessEntityId: maskPhoneNumber(requestPhone),
          scene: 'login',
        ),
      );
    } catch (cause) {
      if (_discardStaleSmsResult(requestPhone)) {
        return;
      }
      _setFailure(
        _unexpectedAuthFailure('AUTH_SMS_REQUEST_FAILED', cause),
        null,
      );
      return;
    }

    if (_discardStaleSmsResult(requestPhone)) {
      return;
    }
    if (!result.ok) {
      _setFailure(result.error!, result.traceId);
      return;
    }

    _setState(
      _state.copyWith(
        smsRequestId: result.value!.smsRequestId,
        cooldownUntil: _currentTime().add(
          Duration(seconds: _cooldownSeconds(result.value!.cooldownSeconds)),
        ),
        code: '',
        status: AuthSubmissionStatus.idle,
        lastErrorCode: null,
        traceId: result.traceId,
      ),
    );
  }

  bool _discardStaleSmsResult(String requestPhone) {
    if (_state.phone == requestPhone) {
      return false;
    }
    _setState(
      _state.copyWith(
        smsRequestId: null,
        cooldownUntil: null,
        status: AuthSubmissionStatus.idle,
        lastErrorCode: null,
        traceId: null,
      ),
    );
    return true;
  }

  Future<void> login() async {
    if (_state.isLoggingIn) {
      _setState(
        _state.copyWith(lastErrorCode: 'AUTH_LOGIN_IN_PROGRESS', traceId: null),
      );
      return;
    }
    final localError = _validateLoginDraft();
    if (localError != null) {
      _setError(localError);
      return;
    }

    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.loggingIn,
        lastErrorCode: null,
        traceId: null,
      ),
    );

    final draft = _LoginDraftSnapshot.fromState(_state);
    final AuthApiResult<SmsLoginResponse> result;
    try {
      result = await _authApi.login(
        request: SmsLoginRequest(
          phone: draft.phone,
          smsRequestId: draft.smsRequestId,
          code: draft.code,
          deviceId: _deviceId,
          agreementAccepted: draft.agreementAccepted,
          clientVersion: _clientVersion,
          timeZone: _userTimeZoneIsFallback ? null : _userTimeZone,
        ),
        correlationId: _correlationId('auth-login'),
        idempotency: IdempotencyRequestContext(
          operation: 'auth-login',
          businessEntityId: maskPhoneNumber(draft.phone),
          scene: 'login',
        ),
      );
    } catch (cause) {
      if (_discardStaleLoginResult(draft)) {
        return;
      }
      _setFailure(
        _unexpectedAuthFailure('AUTH_LOGIN_REQUEST_FAILED', cause),
        null,
      );
      return;
    }

    if (_discardStaleLoginResult(draft)) {
      return;
    }
    if (!result.ok) {
      _setFailure(result.error!, result.traceId);
      return;
    }

    final loginResponse = result.value!;
    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.committingLogin,
        lastErrorCode: null,
        traceId: result.traceId,
      ),
    );
    final AuthApiResult<SessionUserStatus> statusResult;
    try {
      statusResult = await _authApi.getUserStatus(
        accessToken: loginResponse.tokens.accessToken,
        correlationId: _correlationId('auth-login-verify'),
      );
    } catch (cause) {
      _setFailure(
        _unexpectedAuthFailure('AUTH_SESSION_VALIDATION_FAILED', cause),
        result.traceId,
      );
      return;
    }
    if (!statusResult.ok) {
      _setFailure(statusResult.error!, statusResult.traceId ?? result.traceId);
      return;
    }

    final verifiedStatus = statusResult.value!;
    if (verifiedStatus.user.userId != loginResponse.user.userId) {
      _setFailure(
        const AppFailure(
          code: 'AUTH_SESSION_IDENTITY_MISMATCH',
          category: AppFailureCategory.auth,
          message: 'Verified session identity does not match login response',
          userMessageKey: 'auth.error.sessionValidation',
          recoveryActions: <String>['login'],
        ),
        statusResult.traceId ?? result.traceId,
      );
      return;
    }

    final timeZoneFailure = await _repairMissingUserTimeZone(
      status: verifiedStatus,
      accessToken: loginResponse.tokens.accessToken,
    );
    if (_disposed || _discardStaleLoginResult(draft)) return;
    if (timeZoneFailure != null) {
      _setFailure(timeZoneFailure, statusResult.traceId ?? result.traceId);
      return;
    }

    final now = _currentTime();
    final sessionResult = await _sessionStore.applyLoginSuccess(
      tokens: loginResponse.tokens,
      firstLoginThisSession: loginResponse.firstLogin,
      snapshot: userStatusToSessionSnapshot(
        verifiedStatus,
        now,
        onboardingRequiredFallback: loginResponse.onboardingRequired,
      ),
      verifiedStatus: verifiedStatus,
      updatedAt: now,
    );
    if (!sessionResult.ok) {
      _setFailure(sessionResult.error!, result.traceId);
      return;
    }

    _setState(
      const AuthControllerState().copyWith(
        traceId: statusResult.traceId ?? result.traceId,
      ),
    );
  }

  bool _discardStaleLoginResult(_LoginDraftSnapshot draft) {
    if (draft.matches(_state)) {
      return false;
    }
    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.idle,
        lastErrorCode: null,
        traceId: null,
      ),
    );
    return true;
  }

  Future<AppFailure?> _repairMissingUserTimeZone({
    required SessionUserStatus status,
    required String accessToken,
  }) async {
    final desiredTimeZone = _userTimeZone;
    if (status.timeZone == desiredTimeZone) return null;
    if (_userTimeZoneIsFallback && status.timeZone != null) return null;
    final api = _userTimeZoneApi;
    if (api == null) return null;
    try {
      final result = await api.updateUserTimeZone(
        timeZone: desiredTimeZone,
        accessToken: accessToken,
        correlationId: _correlationId('auth-login-timezone'),
        idempotency: IdempotencyRequestContext(
          operation: 'update-me-timezone',
          businessEntityId: status.user.userId,
          scene: 'login-timezone-repair',
        ),
      );
      if (!result.ok) {
        return result.error ?? _userTimeZoneUnavailableFailure();
      }
      if (result.value?.timeZone != desiredTimeZone) {
        return _userTimeZoneUnavailableFailure();
      }
      return null;
    } catch (error) {
      return _userTimeZoneUnavailableFailure(cause: error);
    }
  }

  String? _validateLoginDraft() {
    if (!_state.phoneValid) {
      return 'AUTH_PHONE_INVALID';
    }
    if (_state.smsRequestId == null) {
      return 'AUTH_SMS_REQUEST_MISSING';
    }
    if (!_state.codeValid) {
      return 'AUTH_SMS_CODE_INVALID';
    }
    if (!_state.agreementAccepted) {
      return 'AUTH_AGREEMENT_REQUIRED';
    }
    return null;
  }

  void _setFailure(AppFailure failure, String? traceId) {
    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.idle,
        lastErrorCode: failure.code,
        traceId: traceId,
      ),
    );
  }

  void _setError(String code) {
    _setState(
      _state.copyWith(
        status: AuthSubmissionStatus.idle,
        lastErrorCode: code,
        traceId: null,
      ),
    );
  }

  void _setLoginInProgressError() {
    _setState(
      _state.copyWith(lastErrorCode: 'AUTH_LOGIN_IN_PROGRESS', traceId: null),
    );
  }

  void _setState(AuthControllerState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    notifyListeners();
  }

  DateTime _currentTime() => (_now ?? DateTime.now)().toUtc();

  String _correlationId(String scene) {
    return _correlationIdFactory?.call() ??
        '$scene-${_currentTime().millisecondsSinceEpoch}';
  }
}

bool validatePhoneNumber(String phone) {
  return RegExp(r'^1[3-9]\d{9}$').hasMatch(phone);
}

bool validateSmsCode(String code) {
  return RegExp(r'^\d{6}$').hasMatch(code);
}

String maskPhoneNumber(String phone) {
  if (phone.length < 7) {
    return '***';
  }
  return '${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}';
}

AppFailure _unexpectedAuthFailure(String code, Object cause) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.auth,
    message: 'Authentication request failed',
    userMessageKey: 'auth.error.requestFailed',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
    cause: cause,
  );
}

AppFailure _userTimeZoneUnavailableFailure({Object? cause}) {
  return AppFailure(
    code: 'USER_TIMEZONE_UNAVAILABLE',
    category: AppFailureCategory.api,
    message: 'User timezone could not be persisted',
    userMessageKey: 'auth.error.userTimeZoneUnavailable',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
    cause: cause,
  );
}

int _cooldownSeconds(int serverValue) {
  if (serverValue < 60) {
    return 60;
  }
  return serverValue;
}
