import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/app_cache_policy.dart';
import '../../core/auth/flutter_secure_token_driver.dart';
import '../../core/auth/secure_token_store.dart';
import '../../core/auth/session_store.dart';
import '../../core/device/device_identity_store.dart';
import '../../core/performance/network_metrics.dart';
import '../../features/auth/data/auth_api.dart';
import '../../features/ui_v3/application/profile_capability_controller.dart';
import '../../features/ui_v3/data/profile_capability_ports.dart';
import '../runtime/runtime_provider_module.dart';
import 'app_bootstrap_controller.dart';

final huahuoV3DemoAuthBypassEnabled = resolveHuahuoDebugOnlyFlag(
  isDebugBuild: kDebugMode,
  explicitlyEnabled: const bool.fromEnvironment('HUAHUO_V3_DEMO_AUTH'),
);
const _configuredHuahuoApiBaseUrl = String.fromEnvironment(
  'HUAHUO_API_BASE_URL',
);
const _configuredRecordingApiBaseUrl = String.fromEnvironment(
  'HUAHUO_RECORDING_API_BASE_URL',
  defaultValue: _defaultRecordingApiBaseUrl,
);
const _unconfiguredHuahuoApiBaseUrl = 'https://api.unconfigured.invalid';
const _defaultRecordingApiBaseUrl = 'https://chuda.cc';

bool resolveHuahuoDebugOnlyFlag({
  required bool isDebugBuild,
  required bool explicitlyEnabled,
}) => isDebugBuild && explicitlyEnabled;

const _fallbackUserTimeZone = 'UTC';
const _deviceTimeZoneChannel = MethodChannel('huahuoai/device_timezone');
final _ianaTimeZonePattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_+\-]*/[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*$',
);

String resolveHuahuoUserTimeZone(String? platformTimeZoneName) {
  final candidate = platformTimeZoneName?.trim() ?? '';
  if (isHuahuoIanaTimeZone(candidate)) {
    return candidate;
  }
  return _fallbackUserTimeZone;
}

bool isHuahuoIanaTimeZone(String? value) {
  final candidate = value?.trim() ?? '';
  return candidate == 'UTC' || _ianaTimeZonePattern.hasMatch(candidate);
}

Future<String?> readHuahuoPlatformIanaTimeZone({
  MethodChannel channel = _deviceTimeZoneChannel,
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    final value = await channel
        .invokeMethod<String>('getTimeZone')
        .timeout(timeout);
    final candidate = value?.trim();
    return isHuahuoIanaTimeZone(candidate) ? candidate : null;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  }
}

Uri resolveHuahuoApiBaseUrl({
  required bool isDebugBuild,
  required String configuredValue,
}) {
  final configured = configuredValue.trim();
  final raw = configured.isEmpty && isDebugBuild
      ? _unconfiguredHuahuoApiBaseUrl
      : configured;
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.host.isEmpty ||
      !<String>{'http', 'https'}.contains(uri.scheme)) {
    throw StateError('HUAHUO_API_BASE_URL_INVALID');
  }
  if (!isDebugBuild && uri.scheme != 'https') {
    throw StateError('HUAHUO_API_BASE_URL_HTTPS_REQUIRED');
  }
  return uri;
}

Uri resolveRecordingApiBaseUrl({required String configuredValue}) {
  final uri = Uri.tryParse(configuredValue.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty && uri.path != '/' ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.scheme != 'https') {
    throw StateError('HUAHUO_RECORDING_API_BASE_URL_INVALID');
  }
  return uri;
}

// resident-provider: Shares one secure token driver dependency for the full account session.
final secureTokenDriverProvider = Provider<SecureTokenDriver>((ref) {
  return const FlutterSecureTokenDriver();
});

// resident-provider: Shares one account-scoped secure token store identity across dependent controllers.
final secureTokenStoreProvider = Provider<SecureTokenStore>((ref) {
  return SecureTokenStore(driver: ref.watch(secureTokenDriverProvider));
});

// resident-provider: Shares one device identity driver dependency for the full account session.
final deviceIdentityDriverProvider = Provider<DeviceIdentityDriver>((ref) {
  return ResilientDeviceIdentityDriver(
    primary: const FlutterSecureDeviceIdentityDriver(),
    fallback: ApplicationSupportDeviceIdentityDriver(),
  );
});

// resident-provider: Shares one account-scoped device identity store identity across dependent controllers.
final deviceIdentityStoreProvider = Provider<DeviceIdentityStore>((ref) {
  return DeviceIdentityStore(driver: ref.watch(deviceIdentityDriverProvider));
});

// resident-provider: Keeps the resolved device id value consistent across sibling route consumers.
final resolvedDeviceIdProvider = Provider<String>((ref) {
  throw StateError('DEVICE_IDENTITY_NOT_RESOLVED');
});

// resident-provider: Shares one account-scoped session store identity across dependent controllers.
final sessionStoreProvider = ChangeNotifierProvider<SessionStore>((ref) {
  return SessionStore(secureTokenStore: ref.watch(secureTokenStoreProvider));
});

// resident-provider: Keeps the authenticated user data scope value consistent across sibling route consumers.
final authenticatedUserDataScopeProvider = Provider<String>((ref) {
  return ref.watch(
    sessionStoreProvider.select(
      (store) => store.state.user?.userId ?? 'anonymous',
    ),
  );
});

String knowledgeLibraryWorkspaceCacheScope(
  String userScope,
  SessionState session,
) {
  final normalizedUserScope = userScope.trim();
  if (session.authState != SessionAuthState.authenticated ||
      normalizedUserScope.isEmpty ||
      normalizedUserScope == 'anonymous') {
    return 'anonymous';
  }
  final workspaceId = session.workspace?.workspaceId?.trim();
  if (session.workspaceStatus != SessionWorkspaceStatus.ready ||
      workspaceId == null ||
      workspaceId.isEmpty) {
    return '$normalizedUserScope\u0000workspace-unavailable';
  }
  return '$normalizedUserScope\u0000$workspaceId';
}

String? readyWorkspaceId(SessionState session) {
  final workspaceId = session.workspace?.workspaceId?.trim();
  if (session.authState != SessionAuthState.authenticated ||
      session.workspaceStatus != SessionWorkspaceStatus.ready ||
      workspaceId == null ||
      workspaceId.isEmpty) {
    return null;
  }
  return workspaceId;
}

String? authenticatedRuntimeUserId(SessionState state) {
  if (state.authState != SessionAuthState.authenticated) return null;
  final userId = state.user?.userId;
  if (userId == null || !_isSafeAccountScope(userId)) return null;
  return userId;
}

bool _isSafeAccountScope(String value) {
  return RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(value);
}

// resident-provider: Keeps the authenticated recording user scope value consistent across sibling route consumers.
/// Recording files and recovery state have no anonymous owner. This scope is
/// intentionally null until the session has a verified authenticated user.
final authenticatedRecordingUserScopeProvider = Provider<String?>((ref) {
  final state = ref.watch(sessionStoreProvider).state;
  if (state.authState != SessionAuthState.authenticated) return null;
  final userId = state.user?.userId.trim();
  return userId == null || userId.isEmpty ? null : userId;
});

final class RuntimeClientMetadata {
  const RuntimeClientMetadata({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.locale,
    required this.timeZone,
    this.timeZoneIsFallback = false,
  });

  final String version;
  final String buildNumber;
  final String platform;
  final String locale;
  final String timeZone;
  final bool timeZoneIsFallback;

  String get clientVersion =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';

  ApiClientRuntime runtimeForDevice(String deviceId) => ApiClientRuntime(
    clientVersion: clientVersion,
    deviceId: deviceId,
    platform: platform,
    locale: locale,
    timeZone: timeZone,
  );
}

final class RuntimePackageMetadata {
  const RuntimePackageMetadata({
    required this.version,
    required this.buildNumber,
  });

  final String version;
  final String buildNumber;
}

Future<RuntimeClientMetadata> resolveRuntimeClientMetadata({
  required Future<String?> Function() readNativeTimeZone,
  required Future<RuntimePackageMetadata> Function() readPackageMetadata,
  required String dartTimeZoneName,
  required String platform,
  required String locale,
  Duration timeout = const Duration(seconds: 2),
  String fallbackVersion = const String.fromEnvironment(
    'HUAHUO_CLIENT_VERSION',
    defaultValue: '0.1.0',
  ),
  String fallbackBuildNumber = const String.fromEnvironment(
    'HUAHUO_CLIENT_BUILD',
    defaultValue: '1',
  ),
}) async {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }
  final timeZoneFuture = _boundedMetadataRead(readNativeTimeZone, timeout);
  final packageFuture = _boundedMetadataRead(readPackageMetadata, timeout);
  final nativeCandidate = (await timeZoneFuture)?.trim();
  final nativeTimeZone = isHuahuoIanaTimeZone(nativeCandidate)
      ? nativeCandidate
      : null;
  final package = await packageFuture;
  final dartTimeZone = resolveHuahuoUserTimeZone(dartTimeZoneName);
  return RuntimeClientMetadata(
    version: package?.version.trim().isNotEmpty == true
        ? package!.version.trim()
        : fallbackVersion,
    buildNumber: package?.buildNumber.trim().isNotEmpty == true
        ? package!.buildNumber.trim()
        : fallbackBuildNumber,
    platform: platform,
    locale: locale,
    timeZone: nativeTimeZone ?? dartTimeZone,
    timeZoneIsFallback:
        nativeTimeZone == null && !isHuahuoIanaTimeZone(dartTimeZoneName),
  );
}

Future<T?> _boundedMetadataRead<T>(
  Future<T> Function() read,
  Duration timeout,
) async {
  try {
    return await read().timeout(timeout);
  } catch (_) {
    return null;
  }
}

// resident-provider: Keeps the runtime client metadata value consistent across sibling route consumers.
final runtimeClientMetadataProvider = Provider<RuntimeClientMetadata>((ref) {
  final platformTimeZoneName = DateTime.now().timeZoneName;
  return RuntimeClientMetadata(
    version: const String.fromEnvironment(
      'HUAHUO_CLIENT_VERSION',
      defaultValue: '0.1.0',
    ),
    buildNumber: const String.fromEnvironment(
      'HUAHUO_CLIENT_BUILD',
      defaultValue: '1',
    ),
    platform: Platform.isIOS ? 'ios' : 'android',
    locale: Platform.localeName.replaceAll('_', '-'),
    timeZone: resolveHuahuoUserTimeZone(platformTimeZoneName),
    timeZoneIsFallback: !isHuahuoIanaTimeZone(platformTimeZoneName),
  );
});

// resident-provider: Shares one api transport dependency for the full account session.
final apiTransportProvider = Provider<ApiTransport>((ref) {
  if (_configuredHuahuoApiBaseUrl.trim().isEmpty) {
    return const UnconfiguredApiTransport();
  }
  return InstrumentedApiTransport(
    delegate: HttpApiTransport(),
    metrics: ref.watch(networkMetricsProvider),
  );
});

final class UnconfiguredApiTransport
    implements ApiTransport, ApiStreamingTransport {
  const UnconfiguredApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    return ApiTransportResponse(
      status: HttpStatus.serviceUnavailable,
      body: _errorBody(request),
    );
  }

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    return ApiTransportStreamResponse(
      status: HttpStatus.serviceUnavailable,
      headers: const <String, String>{},
      errorBody: _errorBody(request),
      events: const Stream<ApiTransportStreamEvent>.empty(),
    );
  }

  Map<String, Object?> _errorBody(ApiTransportRequest request) {
    return <String, Object?>{
      'success': false,
      'traceId': request.headers['X-Trace-Id'],
      'error': const <String, Object?>{
        'code': 'API_BASE_URL_UNCONFIGURED',
        'message': 'Backend API URL is not configured',
        'userMessageKey': 'error.api.baseUrlUnconfigured',
        'retryable': false,
      },
    };
  }
}

// resident-provider: Preserves the auth session refresh coordinator dependency identity across route changes.
final authSessionRefreshCoordinatorProvider =
    Provider<AuthSessionRefreshCoordinator>((ref) {
      final metadata = ref.watch(runtimeClientMetadataProvider);
      final deviceId = ref.watch(resolvedDeviceIdProvider);
      final refreshClient = ApiClientFactory.create(
        baseUrl: resolveHuahuoApiBaseUrl(
          isDebugBuild: kDebugMode,
          configuredValue: _configuredHuahuoApiBaseUrl,
        ),
        runtime: metadata.runtimeForDevice(deviceId),
        transport: ref.watch(apiTransportProvider),
      );
      return AuthSessionRefreshCoordinator(
        secureTokenStore: ref.read(secureTokenStoreProvider),
        sessionStore: ref.read(sessionStoreProvider),
        authApi: AuthApi(apiClient: refreshClient),
      );
    });

// resident-provider: Shares one api client dependency for the full account session.
final apiClientProvider = Provider<ApiClient>((ref) {
  final tokenStore = ref.read(secureTokenStoreProvider);
  final sessionStore = ref.read(sessionStoreProvider);
  final sessionRefresh = ref.watch(authSessionRefreshCoordinatorProvider);
  final deviceId = ref.watch(resolvedDeviceIdProvider);
  final metadata = ref.watch(runtimeClientMetadataProvider);
  final baseUrl = resolveHuahuoApiBaseUrl(
    isDebugBuild: kDebugMode,
    configuredValue: _configuredHuahuoApiBaseUrl,
  );
  final transport = ref.watch(apiTransportProvider);
  return ApiClientFactory.create(
    baseUrl: baseUrl,
    runtime: metadata.runtimeForDevice(deviceId),
    transport: transport,
    getAccessToken: () async {
      final result = await tokenStore.getTokens();
      final tokens = result.ok ? result.value : null;
      return tokens == null || isLocalNumericAuthTokens(tokens)
          ? null
          : tokens.accessToken;
    },
    refreshAccessToken: ({required rejectedAccessToken, required failure}) =>
        sessionRefresh.refresh(
          rejectedAccessToken: rejectedAccessToken,
          failure: failure,
        ),
    onAuthExpired: (failure) async {
      if (!_isVerifiedMainSessionExpiry(failure)) return;
      final stored = await tokenStore.getTokens();
      if (!stored.ok ||
          stored.value == null ||
          isLocalNumericAuthTokens(stored.value!)) {
        return;
      }
      await tokenStore.clearTokens(SecureTokenClearReason.unauthorized);
      sessionStore.restoreExpired(
        errorCode: failure.code,
        restoredAt: DateTime.now().toUtc(),
      );
    },
  );
});

bool _isVerifiedMainSessionExpiry(AppFailure failure) => const <String>{
  'AUTH_SESSION_EXPIRED',
  'TOKEN_EXPIRED',
  'UNAUTHORIZED',
  'AUTH_UNAUTHORIZED',
}.contains(failure.code.trim());

// resident-provider: Shares one recording api client dependency for the full account session.
final recordingApiClientProvider = Provider<ApiClient>((ref) {
  final mainClient = ref.watch(apiClientProvider);
  final mainConfig = mainClient.config;
  return ApiClientFactory.create(
    baseUrl: resolveRecordingApiBaseUrl(
      configuredValue: _configuredRecordingApiBaseUrl,
    ),
    runtime: ApiClientRuntime(
      clientVersion: mainConfig.clientVersion,
      deviceId: mainConfig.deviceId,
      platform: mainConfig.platform,
      locale: mainConfig.locale,
      timeZone: mainConfig.timeZone,
    ),
    transport: ref.watch(apiTransportProvider),
    getAccessToken: mainConfig.getAccessToken,
    traceIdFactory: mainConfig.traceIdFactory,
    requestTimeout: mainConfig.requestTimeout,
  );
});

// resident-provider: Shares one profile version port dependency for the full account session.
final profileVersionPortProvider = Provider<ProfileVersionPort>((ref) {
  return ProfileVersionApiPort(apiClient: ref.watch(apiClientProvider));
});

final profileVersionControllerProvider =
    Provider.autoDispose<ProfileVersionController>(
      (ref) => ProfileVersionController(ref.watch(profileVersionPortProvider)),
    );

// resident-provider: Keeps the app cache policy value consistent across sibling route consumers.
final appCachePolicyProvider = Provider<AppCachePolicy>((ref) {
  try {
    return AppCachePolicy(apiClient: ref.watch(apiClientProvider));
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return AppCachePolicy();
    }
    rethrow;
  }
});
