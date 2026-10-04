import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/auth/data/auth_api.dart';
import '../bootstrap/app_bootstrap_controller.dart';
import '../bootstrap/core_provider_module.dart';

// resident-provider: Shares one auth api dependency for the full account session.
final authApiProvider = Provider<AuthApiPort>((ref) {
  return AuthApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Preserves the app bootstrap controller state machine across route transitions.
final appBootstrapControllerProvider =
    ChangeNotifierProvider<AppBootstrapController>((ref) {
      final authApi = ref.read(authApiProvider);
      final metadata = ref.read(runtimeClientMetadataProvider);
      final UserTimeZoneApiPort? userTimeZoneApi =
          authApi is UserTimeZoneApiPort
          ? authApi as UserTimeZoneApiPort
          : null;
      final controller = AppBootstrapController(
        secureTokenStore: ref.read(secureTokenStoreProvider),
        sessionStore: ref.read(sessionStoreProvider),
        authApi: authApi,
        sessionRefresh: ref.read(authSessionRefreshCoordinatorProvider),
        userTimeZone: metadata.timeZone,
        userTimeZoneIsFallback: metadata.timeZoneIsFallback,
        userTimeZoneApi: userTimeZoneApi,
      );
      unawaited(
        Future<void>.microtask(controller.restore).catchError((Object _) {
          controller.markRestoreFailed('SESSION_RESTORE_TRIGGER_FAILED');
        }),
      );
      return controller;
    });

// resident-provider: Preserves the auth controller state machine across route transitions.
final authControllerProvider = ChangeNotifierProvider<AuthController>((ref) {
  final metadata = ref.watch(runtimeClientMetadataProvider);
  final authApi = ref.read(authApiProvider);
  final UserTimeZoneApiPort? userTimeZoneApi = authApi is UserTimeZoneApiPort
      ? authApi as UserTimeZoneApiPort
      : null;
  return AuthController(
    authApi: authApi,
    sessionStore: ref.read(sessionStoreProvider),
    deviceId: ref.watch(resolvedDeviceIdProvider),
    clientVersion: metadata.clientVersion,
    userTimeZone: metadata.timeZone,
    userTimeZoneIsFallback: metadata.timeZoneIsFallback,
    userTimeZoneApi: userTimeZoneApi,
  );
});
