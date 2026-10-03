import 'dart:async';
import 'dart:convert';

import '../api/api_envelope.dart';

final class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;

  bool get isValid => accessToken.isNotEmpty && refreshToken.isNotEmpty;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'accessToken': accessToken,
      'refreshToken': refreshToken,
    };
  }
}

final class AuthSessionRecoveryHint {
  const AuthSessionRecoveryHint({
    required this.userId,
    required this.maskedPhoneNumber,
    required this.workspaceStatus,
    required this.onboardingRequired,
    this.basicPositioningCompleted,
    this.positioningStatus,
    this.coldStartPercent,
    this.completedPercent,
  });

  final String userId;
  final String maskedPhoneNumber;
  final String workspaceStatus;
  final bool onboardingRequired;
  final bool? basicPositioningCompleted;
  final String? positioningStatus;
  final int? coldStartPercent;
  final int? completedPercent;

  Map<String, Object?> toJson() => <String, Object?>{
    'userId': userId,
    'maskedPhoneNumber': maskedPhoneNumber,
    'workspaceStatus': workspaceStatus,
    'onboardingRequired': onboardingRequired,
    if (basicPositioningCompleted != null)
      'basicPositioningCompleted': basicPositioningCompleted,
    if (positioningStatus != null) 'positioningStatus': positioningStatus,
    if (coldStartPercent != null) 'coldStartPercent': coldStartPercent,
    if (completedPercent != null) 'completedPercent': completedPercent,
  };
}

final class SecureTokenCredential {
  const SecureTokenCredential({required this.username, required this.password});

  final String username;
  final String password;
}

abstract interface class SecureTokenDriver {
  FutureOr<SecureTokenCredential?> read({required String service});
  FutureOr<bool> write({
    required String service,
    required String username,
    required String password,
  });
  FutureOr<bool> clear({required String service});
}

enum SecureTokenClearReason {
  logout,
  unauthorized,
  tokenExpired,
  corrupted,
  userSwitch,
}

final class SecureTokenResult<T> {
  const SecureTokenResult._({required this.ok, this.value, this.error});

  factory SecureTokenResult.success(T value) {
    return SecureTokenResult<T>._(ok: true, value: value);
  }

  factory SecureTokenResult.failure(AppFailure error) {
    return SecureTokenResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class SecureTokenStore {
  const SecureTokenStore({
    required SecureTokenDriver driver,
    this.service = tokenService,
  }) : _driver = driver;

  static const tokenService = 'huahuo.ai.session.tokens';
  static const tokenUsername = 'session';

  final SecureTokenDriver _driver;
  final String service;

  Future<SecureTokenResult<AuthTokens?>> getTokens() async {
    try {
      final credential = await _driver.read(service: service);
      if (credential == null) {
        return SecureTokenResult<AuthTokens?>.success(null);
      }
      final parsed = _parseCredential(credential);
      if (!parsed.ok) {
        return SecureTokenResult<AuthTokens?>.failure(parsed.error!);
      }
      return SecureTokenResult<AuthTokens?>.success(parsed.value);
    } catch (cause) {
      return SecureTokenResult<AuthTokens?>.failure(
        _secureTokenError('SECURE_TOKEN_READ_FAILED', cause),
      );
    }
  }

  Future<SecureTokenResult<void>> setTokens(
    AuthTokens tokens, {
    AuthSessionRecoveryHint? recoveryHint,
  }) async {
    if (!tokens.isValid ||
        (recoveryHint != null && !_isSafeRecoveryHint(recoveryHint))) {
      return SecureTokenResult<void>.failure(
        _secureTokenError('SECURE_TOKEN_INVALID_PAIR'),
      );
    }
    try {
      final stored = await _driver.write(
        service: service,
        username: tokenUsername,
        password: jsonEncode(<String, Object?>{
          ...tokens.toJson(),
          if (recoveryHint != null) 'recoveryHint': recoveryHint.toJson(),
        }),
      );
      if (!stored) {
        return SecureTokenResult<void>.failure(
          _secureTokenError('SECURE_TOKEN_WRITE_FAILED'),
        );
      }
      return SecureTokenResult<void>.success(null);
    } catch (cause) {
      return SecureTokenResult<void>.failure(
        _secureTokenError('SECURE_TOKEN_WRITE_FAILED', cause),
      );
    }
  }

  Future<SecureTokenResult<AuthSessionRecoveryHint?>> getRecoveryHint() async {
    try {
      final credential = await _driver.read(service: service);
      if (credential == null) {
        return SecureTokenResult<AuthSessionRecoveryHint?>.success(null);
      }
      final parsed = _parseCredential(credential);
      if (!parsed.ok) {
        return SecureTokenResult<AuthSessionRecoveryHint?>.failure(
          parsed.error!,
        );
      }
      final hint = _parseRecoveryHint(credential);
      if (!hint.ok) {
        return SecureTokenResult<AuthSessionRecoveryHint?>.failure(hint.error!);
      }
      return SecureTokenResult<AuthSessionRecoveryHint?>.success(hint.value);
    } catch (cause) {
      return SecureTokenResult<AuthSessionRecoveryHint?>.failure(
        _secureTokenError('SECURE_TOKEN_READ_FAILED', cause),
      );
    }
  }

  Future<SecureTokenResult<void>> clearTokens(
    SecureTokenClearReason reason,
  ) async {
    try {
      final cleared = await _driver.clear(service: service);
      if (!cleared) {
        return SecureTokenResult<void>.failure(
          _secureTokenError('SECURE_TOKEN_CLEAR_FAILED'),
        );
      }
      return SecureTokenResult<void>.success(null);
    } catch (cause) {
      return SecureTokenResult<void>.failure(
        _secureTokenError('SECURE_TOKEN_CLEAR_FAILED', cause),
      );
    }
  }

  Future<SecureTokenResult<Object>> hasStoredSession() async {
    try {
      final credential = await _driver.read(service: service);
      if (credential == null) {
        return SecureTokenResult<Object>.success(false);
      }
      if (!_isStoredSessionCredential(credential)) {
        return SecureTokenResult<Object>.success('unknown');
      }
      return SecureTokenResult<Object>.success(true);
    } catch (_) {
      return SecureTokenResult<Object>.success('unknown');
    }
  }
}

SecureTokenResult<AuthTokens> _parseCredential(
  SecureTokenCredential credential,
) {
  if (credential.username != SecureTokenStore.tokenUsername) {
    return SecureTokenResult<AuthTokens>.failure(
      _secureTokenError('SECURE_TOKEN_CORRUPTED'),
    );
  }
  try {
    final raw = jsonDecode(credential.password);
    final object = asObjectMap(raw);
    final accessToken = asNonEmptyString(object?['accessToken']);
    final refreshToken = asNonEmptyString(object?['refreshToken']);
    if (accessToken != null && refreshToken != null) {
      return SecureTokenResult<AuthTokens>.success(
        AuthTokens(accessToken: accessToken, refreshToken: refreshToken),
      );
    }
  } catch (_) {
    // Fall through to corrupted.
  }
  return SecureTokenResult<AuthTokens>.failure(
    _secureTokenError('SECURE_TOKEN_CORRUPTED'),
  );
}

bool _isStoredSessionCredential(SecureTokenCredential credential) {
  return _parseCredential(credential).ok;
}

SecureTokenResult<AuthSessionRecoveryHint?> _parseRecoveryHint(
  SecureTokenCredential credential,
) {
  try {
    final object = asObjectMap(jsonDecode(credential.password));
    final raw = object?['recoveryHint'];
    if (raw == null) {
      return SecureTokenResult<AuthSessionRecoveryHint?>.success(null);
    }
    final hintObject = asObjectMap(raw);
    final userId = asNonEmptyString(hintObject?['userId']);
    final maskedPhoneNumber = asNonEmptyString(
      hintObject?['maskedPhoneNumber'],
    );
    final workspaceStatus = asNonEmptyString(hintObject?['workspaceStatus']);
    final onboardingRequired = hintObject?['onboardingRequired'];
    final basicPositioningCompleted = hintObject?['basicPositioningCompleted'];
    final positioningStatus = asNonEmptyString(
      hintObject?['positioningStatus'],
    );
    final coldStartPercent = _percentage(hintObject?['coldStartPercent']);
    final completedPercent = _percentage(hintObject?['completedPercent']);
    final hint =
        userId == null ||
            maskedPhoneNumber == null ||
            workspaceStatus == null ||
            onboardingRequired is! bool ||
            (basicPositioningCompleted != null &&
                basicPositioningCompleted is! bool) ||
            (hintObject?['coldStartPercent'] != null &&
                coldStartPercent == null) ||
            (hintObject?['completedPercent'] != null &&
                completedPercent == null)
        ? null
        : AuthSessionRecoveryHint(
            userId: userId,
            maskedPhoneNumber: maskedPhoneNumber,
            workspaceStatus: workspaceStatus,
            onboardingRequired: onboardingRequired,
            basicPositioningCompleted: basicPositioningCompleted as bool?,
            positioningStatus: positioningStatus,
            coldStartPercent: coldStartPercent,
            completedPercent: completedPercent,
          );
    if (hint == null || !_isSafeRecoveryHint(hint)) {
      return SecureTokenResult<AuthSessionRecoveryHint?>.failure(
        _secureTokenError('SECURE_TOKEN_CORRUPTED'),
      );
    }
    return SecureTokenResult<AuthSessionRecoveryHint?>.success(hint);
  } catch (_) {
    return SecureTokenResult<AuthSessionRecoveryHint?>.failure(
      _secureTokenError('SECURE_TOKEN_CORRUPTED'),
    );
  }
}

bool _isSafeRecoveryHint(AuthSessionRecoveryHint hint) {
  return RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(hint.userId) &&
      RegExp(r'^\d{3}\*{4}\d{4}$').hasMatch(hint.maskedPhoneNumber) &&
      (hint.workspaceStatus == 'ready' ||
          hint.workspaceStatus == 'creating' ||
          hint.workspaceStatus == 'sync_failed') &&
      (hint.positioningStatus == null ||
          hint.positioningStatus == 'not_started' ||
          hint.positioningStatus == 'in_progress' ||
          hint.positioningStatus == 'completed') &&
      _isPercentage(hint.coldStartPercent) &&
      _isPercentage(hint.completedPercent);
}

int? _percentage(Object? value) {
  if (value is! int || value < 0 || value > 100) return null;
  return value;
}

bool _isPercentage(int? value) => value == null || (value >= 0 && value <= 100);

AppFailure _secureTokenError(String code, [Object? cause]) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.auth,
    message: 'Secure session storage operation failed',
    userMessageKey: 'auth.error.secureTokenStore',
    isRetryable: code != 'SECURE_TOKEN_INVALID_PAIR',
    recoveryActions: code == 'SECURE_TOKEN_INVALID_PAIR'
        ? const <String>['none']
        : const <String>['login', 'retry'],
    cause: cause,
  );
}
