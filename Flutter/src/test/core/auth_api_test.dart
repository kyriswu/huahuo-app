import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';

void main() {
  group('AuthApi', () {
    test('sendSmsCode uses remote adapter and parses request id', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'smsRequestId': 'sms-1',
              'cooldownSeconds': 75,
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendSmsCode(
        phone: '13812348000',
        correlationId: 'trace_auth_sms',
        idempotency: const IdempotencyRequestContext(
          operation: 'auth-sms-code',
          businessEntityId: '138****8000',
          scene: 'login',
        ),
      );

      expect(result.ok, isTrue);
      expect(result.value?.smsRequestId, 'sms-1');
      expect(result.value?.cooldownSeconds, 75);
      expect(transport.requests.single.method, 'POST');
      expect(transport.requests.single.url.path, '/api/v1/auth/sms-code');
      expect(
        transport.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(_jsonBody(transport.requests.single)['phone'], '13812348000');
    });

    test('sendSmsCode accepts prelaunch direct success object', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'smsRequestId': 'sms-direct-1',
            'cooldownSeconds': 90,
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendSmsCode(
        phone: '13812348000',
        correlationId: 'trace_auth_sms',
      );

      expect(result.ok, isTrue);
      expect(result.value?.smsRequestId, 'sms-direct-1');
      expect(result.value?.cooldownSeconds, 90);
      expect(transport.requests.single.url.path, '/api/v1/auth/sms-code');
    });

    test('sendSmsCode rejects direct sent status without request id', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'status': 'sent', 'cooldownSeconds': 60},
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendSmsCode(
        phone: '13812348000',
        correlationId: 'trace_auth_sms',
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SMS_REQUEST_ID_MISSING');
      expect(result.retryAfterSeconds, 60);
    });

    test('sendSmsCode normalizes provider direct failure codes', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'errorCode': 'SMS_PROVIDER_TIMEOUT',
            'retryable': true,
            'cooldownSeconds': 30,
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendSmsCode(
        phone: '13812348000',
        correlationId: 'trace_auth_sms',
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SMS_PROVIDER_FAILED');
      expect(result.error?.isRetryable, isTrue);
      expect(result.retryAfterSeconds, 30);
    });

    test(
      'sendSmsCode preserves a provider rejection for UI diagnosis',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'status': 'failed',
                'errorCode': 'SMS_PROVIDER_REJECTED',
                'retryable': false,
              },
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.sendSmsCode(
          phone: '13812348000',
          correlationId: 'trace_auth_sms_rejected',
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'SMS_PROVIDER_REJECTED');
        expect(result.error?.isRetryable, isFalse);
      },
    );

    test('sendSmsCode normalizes provider envelope failure codes', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'SMS_PROVIDER_RATE_LIMITED',
              'retryable': true,
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.sendSmsCode(
        phone: '13812348000',
        correlationId: 'trace_auth_sms',
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SMS_RATE_LIMITED');
      expect(result.error?.userMessageKey, 'api.error.SMS_RATE_LIMITED');
    });

    test(
      'login uses remote adapter and parses token session projection',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'traceId': 'trace_login',
              'data': <String, Object?>{
                'tokenType': 'Bearer',
                'accessToken': 'access_1',
                'refreshToken': 'refresh_1',
                'firstLogin': true,
                'user': <String, Object?>{
                  'userId': 'user-1',
                  'phoneMasked': '138****8000',
                },
                'workspace': <String, Object?>{
                  'status': 'ready',
                  'defaultContentLineId': 'line-1',
                },
              },
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.login(
          request: const SmsLoginRequest(
            phone: '13812348000',
            smsRequestId: 'sms-1',
            code: '112233',
            deviceId: 'device-1',
            agreementAccepted: true,
            clientVersion: '0.1.0',
            timeZone: 'Asia/Shanghai',
          ),
          correlationId: 'trace_login',
          idempotency: const IdempotencyRequestContext(
            operation: 'auth-login',
            businessEntityId: '138****8000',
            scene: 'login',
          ),
        );

        expect(result.ok, isTrue);
        expect(result.value?.tokens.accessToken, 'access_1');
        expect(result.value?.workspaceStatus, SessionWorkspaceStatus.ready);
        expect(result.value?.firstLogin, isTrue);
        expect(transport.requests.single.method, 'POST');
        expect(transport.requests.single.url.path, '/api/v1/auth/login');
        expect(
          transport.requests.single.headers.containsKey('Authorization'),
          isFalse,
        );
        expect(_jsonBody(transport.requests.single)['smsRequestId'], 'sms-1');
        expect(_jsonBody(transport.requests.single)['smsCode'], '112233');
        expect(
          _jsonBody(transport.requests.single).containsKey('code'),
          isFalse,
        );
        expect(
          _jsonBody(transport.requests.single)['timeZone'],
          'Asia/Shanghai',
        );
      },
    );

    test(
      'login request omits an explicitly unavailable fallback time zone',
      () {
        const request = SmsLoginRequest(
          phone: '13812348000',
          smsRequestId: 'sms-1',
          code: '112233',
          deviceId: 'device-1',
          agreementAccepted: true,
          clientVersion: '0.1.0',
          timeZone: null,
        );

        expect(request.toJson().containsKey('timeZone'), isFalse);
      },
    );

    test('login defaults to the reviewed legal document versions', () {
      const request = SmsLoginRequest(
        phone: '13812348000',
        smsRequestId: 'sms-1',
        code: '112233',
        deviceId: 'device-1',
        agreementAccepted: true,
        clientVersion: '0.1.0',
      );

      expect(request.toJson()['agreementVersion'], '2026-08-20');
      expect(request.toJson()['privacyVersion'], '2026-08-20');
    });

    test('login projects current basic-positioning fields', () {
      final response = parseSmsLoginResponse(<String, Object?>{
        'accessToken': 'access_1',
        'refreshToken': 'refresh_1',
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneMasked': '138****8000',
        },
        'workspace': <String, Object?>{'status': 'ready'},
        'basicPositioningCompleted': false,
        'positioningStatus': 'in_progress',
        'positioningProgress': <String, Object?>{
          'coldStartPercent': 65,
          'coldStartCompleted': false,
          'completedPercent': 24,
        },
      });

      expect(response?.basicPositioningCompleted, isFalse);
      expect(response?.positioningStatus, SessionPositioningStatus.inProgress);
      expect(response?.positioningProgress?.coldStartPercent, 65);
      expect(response?.positioningProgress?.completedPercent, 24);
    });

    test('login accepts rich prelaunch workspace response projection', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'traceId': 'trace_login',
            'data': <String, Object?>{
              'tokenType': 'Bearer',
              'accessToken': 'access_1',
              'refreshToken': 'refresh_1',
              'user': <String, Object?>{
                'userId':
                    'user_e777244a724fee0b7a89e8287fc551d097886125a8d4caaa7eca50708b39856f',
                'phoneMasked': 'e777***856f',
                'status': 'normal',
              },
              'workspace': <String, Object?>{
                'status': 'ready',
                'defaultContentLineId':
                    'content_line_workspace_user_e777244a724fee0b7a89e8287fc551d097886125a8d4caaa7eca50708b39856f_default',
                'hotspotSeed': <String, Object?>{
                  'queue': <String, Object?>{
                    'payload': <String, Object?>{'seedReason': 'registration'},
                  },
                },
              },
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.login(
        request: const SmsLoginRequest(
          phone: '18800000001',
          smsRequestId: 'sms-1',
          code: '112233',
          deviceId: 'device-1',
          agreementAccepted: true,
          clientVersion: '0.1.0',
        ),
        correlationId: 'trace_login',
      );

      expect(result.ok, isTrue);
      expect(result.value?.workspaceStatus, SessionWorkspaceStatus.ready);
      expect(
        result.value?.defaultContentLineId,
        'content_line_workspace_user_e777244a724fee0b7a89e8287fc551d097886125a8d4caaa7eca50708b39856f_default',
      );
    });

    test('login safely projects the live Backend phone hash', () {
      const phoneHash =
          'a7cadb4cf3f03041bf0936753fd297e11372e9e6e0afcc7ceabaef30e262c680';
      final response = parseSmsLoginResponse(<String, Object?>{
        'tokenType': 'Bearer',
        'accessToken': 'access_1',
        'refreshToken': 'refresh_1',
        'user': <String, Object?>{
          'userId': 'user_$phoneHash',
          'phoneHash': phoneHash,
          'status': 'active',
        },
        'onboardingRequired': false,
        'workspace': <String, Object?>{
          'workspaceId': 'workspace_user_$phoneHash',
          'status': 'sync_failed',
          'errorCode': 'WORKSPACE_SYNC_FAILED',
          'retryable': true,
        },
      });

      expect(response, isNotNull);
      expect(response?.workspaceStatus, SessionWorkspaceStatus.syncFailed);
      expect(response?.user.maskedPhoneNumber, 'a7ca***c680');
      expect(response?.user.maskedPhoneNumber, isNot(contains(phoneHash)));
    });

    test('status preserves a nested placeholder creative positioning', () {
      final status = parseUserStatusResponse(<String, Object?>{
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneMasked': '138****8000',
        },
        'workspace': <String, Object?>{
          'workspaceId': 'workspace-1',
          'status': 'ready',
          'creativePositioning': <String, Object?>{
            'creativePositioningId': 'positioning-default',
            'name': 'Default creative positioning',
            'isPlaceholder': true,
          },
        },
        'runningTaskCount': 0,
        'timeZone': 'GMT',
      });

      expect(status?.defaultContentLine?.contentLineId, 'positioning-default');
      expect(status?.defaultContentLine?.isPlaceholder, isTrue);
      expect(status?.timeZone, 'GMT');
      expect(
        userStatusToSessionSnapshot(
          status!,
          DateTime.utc(2026, 8, 9),
        ).onboardingRequired,
        isTrue,
      );
    });

    test('status treats the invalid Local zone as missing', () {
      final status = parseUserStatusResponse(<String, Object?>{
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneMasked': '138****8000',
        },
        'workspace': <String, Object?>{'status': 'ready'},
        'runningTaskCount': 0,
        'timeZone': 'Local',
      });

      expect(status, isNotNull);
      expect(status?.timeZone, isNull);
    });

    test('login rejects a non-canonical phone hash', () {
      final response = parseSmsLoginResponse(<String, Object?>{
        'accessToken': 'access_1',
        'refreshToken': 'refresh_1',
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneHash': 'not-a-canonical-phone-hash',
        },
        'workspace': <String, Object?>{'status': 'ready'},
      });

      expect(response, isNull);
    });

    test('login accepts legacy isNewUser with canonical precedence', () {
      final legacy = parseSmsLoginResponse(<String, Object?>{
        'accessToken': 'access_1',
        'refreshToken': 'refresh_1',
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneMasked': '138****8000',
        },
        'isNewUser': true,
        'workspace': <String, Object?>{'status': 'ready'},
      });
      final canonical = parseSmsLoginResponse(<String, Object?>{
        'accessToken': 'access_1',
        'refreshToken': 'refresh_1',
        'user': <String, Object?>{
          'userId': 'user-1',
          'phoneMasked': '138****8000',
        },
        'firstLogin': false,
        'isNewUser': true,
        'workspace': <String, Object?>{'status': 'ready'},
      });

      expect(legacy?.firstLogin, isTrue);
      expect(canonical?.firstLogin, isFalse);
    });

    test('login rejects non-boolean session decision flags', () {
      for (final field in <String>[
        'onboardingRequired',
        'firstLogin',
        'isNewUser',
      ]) {
        final response = parseSmsLoginResponse(<String, Object?>{
          'accessToken': 'access_1',
          'refreshToken': 'refresh_1',
          'user': <String, Object?>{
            'userId': 'user-1',
            'phoneMasked': '138****8000',
          },
          field: 'true',
          'workspace': <String, Object?>{'status': 'ready'},
        });

        expect(response, isNull, reason: field);
      }
    });

    test(
      'refreshAuthToken uses refresh endpoint without stale auth header',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'traceId': 'trace_refresh',
              'data': <String, Object?>{
                'tokenType': 'Bearer',
                'accessToken': 'new_access',
                'refreshToken': 'new_refresh',
                'rotated': true,
              },
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.refreshAuthToken(
          refreshToken: 'old_refresh',
          correlationId: 'trace_refresh',
          idempotency: const IdempotencyRequestContext(
            operation: 'auth-refresh',
            scene: 'session-restore',
          ),
        );

        expect(result.ok, isTrue);
        expect(result.value?.tokens.accessToken, 'new_access');
        expect(result.value?.tokens.refreshToken, 'new_refresh');
        expect(result.value?.rotated, isTrue);
        expect(transport.requests.single.method, 'POST');
        expect(transport.requests.single.url.path, '/api/v1/auth/refresh');
        expect(
          transport.requests.single.headers.containsKey('Authorization'),
          isFalse,
        );
        expect(_jsonBody(transport.requests.single), <String, Object?>{
          'refreshToken': 'old_refresh',
        });
      },
    );

    test('getUserStatus forwards explicit restored access token', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'userId': 'user-1',
                'phoneMasked': '138****8000',
              },
              'workspace': <String, Object?>{'status': 'ready'},
              'runningTaskCount': 0,
              'timeZone': 'Asia/Shanghai',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'items': <Object?>[]},
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.getUserStatus(
        accessToken: 'restored_access',
        correlationId: 'trace_status',
      );

      expect(result.ok, isTrue);
      expect(result.value?.workspace.status, SessionWorkspaceStatus.ready);
      expect(result.value?.timeZone, 'Asia/Shanghai');
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].method, 'GET');
      expect(transport.requests[0].url.path, '/api/v1/me/status');
      expect(transport.requests[1].method, 'GET');
      expect(transport.requests[1].url.path, '/api/v1/creative-positionings');
      for (final request in transport.requests) {
        expect(request.headers['Authorization'], 'Bearer restored_access');
      }
      expect(result.value?.defaultContentLine, isNull);
    });

    test(
      'getUserStatus enriches stale progress from durable positioning',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'traceId': 'trace_status',
              'data': <String, Object?>{
                'user': <String, Object?>{
                  'userId': 'user-1',
                  'phoneMasked': '138****8000',
                },
                'workspace': <String, Object?>{
                  'workspaceId': 'workspace-1',
                  'status': 'ready',
                },
                'runningTaskCount': 0,
                'onboardingRequired': true,
                'basicPositioningCompleted': false,
                'positioningStatus': 'in_progress',
              },
            },
          ),
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'items': <Object?>[
                  <String, Object?>{
                    'creativePositioningId': 'positioning-1',
                    'name': 'Reading',
                    'status': 'active',
                    'isDefault': true,
                    'isPlaceholder': false,
                  },
                ],
              },
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.getUserStatus(
          accessToken: 'restored_access',
          correlationId: 'trace_status',
        );

        expect(result.ok, isTrue);
        expect(result.traceId, 'trace_status');
        expect(result.value?.basicPositioningCompleted, isFalse);
        expect(
          result.value?.defaultContentLine?.contentLineId,
          'positioning-1',
        );
        expect(result.value?.defaultContentLine?.isPlaceholder, isFalse);
        expect(
          userStatusToSessionSnapshot(
            result.value!,
            DateTime.utc(2026, 8, 11),
          ).onboardingRequired,
          isTrue,
        );
        expect(transport.requests, hasLength(2));
        expect(
          transport.requests[1].headers['Authorization'],
          'Bearer restored_access',
        );
      },
    );

    test('getUserStatus retains Workspace default positioning ID', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'userId': 'user-1',
                'phoneMasked': '138****8000',
              },
              'workspace': <String, Object?>{
                'workspaceId': 'workspace-1',
                'status': 'ready',
                'defaultCreativePositioningId': 'positioning-1',
              },
              'runningTaskCount': 0,
              'basicPositioningCompleted': false,
              'positioningStatus': 'in_progress',
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.getUserStatus(
        accessToken: 'restored_access',
        correlationId: 'trace_status',
      );

      expect(result.ok, isTrue);
      expect(result.value?.workspace.defaultContentLineId, 'positioning-1');
      expect(transport.requests, hasLength(1));
    });

    test('getUserStatus ignores a non-default positioning', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'user': <String, Object?>{
                'userId': 'user-1',
                'phoneMasked': '138****8000',
              },
              'workspace': <String, Object?>{'status': 'ready'},
              'runningTaskCount': 0,
              'basicPositioningCompleted': false,
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'creativePositioningId': 'positioning-secondary',
                  'name': 'Secondary',
                  'status': 'active',
                  'isDefault': false,
                  'isPlaceholder': false,
                },
              ],
            },
          },
        ),
      ]);
      final api = _api(transport);

      final result = await api.getUserStatus(accessToken: 'restored_access');

      expect(result.ok, isTrue);
      expect(result.value?.defaultContentLine, isNull);
    });

    test(
      'updateUserTimeZone uses the authenticated idempotent endpoint',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'timeZone': 'Asia/Shanghai'},
            },
          ),
        ]);
        final api = _api(transport);

        final result = await api.updateUserTimeZone(
          timeZone: 'Asia/Shanghai',
          accessToken: 'restored_access',
          correlationId: 'trace_timezone',
          idempotency: const IdempotencyRequestContext(
            operation: 'update-me-timezone',
            businessEntityId: 'user-1',
            scene: 'session-restore',
          ),
        );

        expect(result.ok, isTrue);
        expect(result.value?.timeZone, 'Asia/Shanghai');
        expect(transport.requests.single.method, 'PUT');
        expect(transport.requests.single.url.path, '/api/v1/me/timezone');
        expect(
          transport.requests.single.headers['Authorization'],
          'Bearer restored_access',
        );
        expect(
          transport.requests.single.headers['X-Idempotency-Key'],
          isNotEmpty,
        );
        expect(_jsonBody(transport.requests.single), <String, Object?>{
          'timeZone': 'Asia/Shanghai',
        });
      },
    );
  });
}

AuthApi _api(_QueueTransport transport) {
  return AuthApi(
    apiClient: ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: '0.1.0',
        deviceId: 'device-1',
        platform: 'ios',
        locale: 'zh-CN',
        getAccessToken: () => 'provider_access',
        traceIdFactory: () => 'trace_default',
      ),
      transport: transport,
    ),
  );
}

Map<String, Object?> _jsonBody(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
