import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_export_service.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/performance/performance_snapshot.dart';
import 'package:huahuoai_app/features/settings/application/settings_controller.dart';

void main() {
  group('SettingsController', () {
    test('updates local daily reminder preferences', () {
      final harness = _SettingsHarness(
        permissionsPort: _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        ),
      );

      harness.controller.setDailyReminderEnabled(true);
      harness.controller.setDailyReminderSchedule(
        DailyReminderSchedule.everyDay,
      );
      harness.controller.setDailyReminderMinutes(24 * 60 + 12);

      expect(harness.controller.state.dailyReminderEnabled, isTrue);
      expect(
        harness.controller.state.dailyReminderSchedule,
        DailyReminderSchedule.everyDay,
      );
      expect(harness.controller.state.dailyReminderMinutes, 1439);
    });

    test('loads permission rows and maps recovery actions', () async {
      final harness = _SettingsHarness(
        permissionsPort: _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{
            PlatformPermissionKind.bluetooth: PlatformPermissionStatus.granted,
            PlatformPermissionKind.microphone: PlatformPermissionStatus.denied,
          },
        ),
      );

      await harness.controller.refreshPermissions();

      final state = harness.controller.state;
      expect(state.permissionLoadStatus, SettingsLoadStatus.loaded);
      final microphone = state.permissionRows.singleWhere(
        (row) => row.kind == PlatformPermissionKind.microphone,
      );
      expect(microphone.status, PlatformPermissionStatus.denied);
      expect(microphone.recoveryAction, PermissionRecoveryAction.request);
    });

    test(
      'requests first-use permission and applies returned native state',
      () async {
        final port = _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{
            PlatformPermissionKind.microphone:
                PlatformPermissionStatus.notDetermined,
          },
          requestedStatuses:
              const <PlatformPermissionKind, PlatformPermissionStatus>{
                PlatformPermissionKind.microphone:
                    PlatformPermissionStatus.granted,
              },
        );
        final harness = _SettingsHarness(permissionsPort: port);

        await harness.controller.requestPermission(
          PlatformPermissionKind.microphone,
        );

        expect(port.requestedKinds, <PlatformPermissionKind>[
          PlatformPermissionKind.microphone,
        ]);
        expect(
          harness.controller.state.permissionRows
              .singleWhere(
                (row) => row.kind == PlatformPermissionKind.microphone,
              )
              .status,
          PlatformPermissionStatus.granted,
        );
        expect(
          harness.controller.state.permissionLoadStatus,
          SettingsLoadStatus.loaded,
        );
      },
    );

    test('latches one permission operation until the native result', () async {
      final requestGate = Completer<void>();
      final port = _FakePermissionsPort(
        statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        requestedStatuses:
            const <PlatformPermissionKind, PlatformPermissionStatus>{
              PlatformPermissionKind.microphone:
                  PlatformPermissionStatus.granted,
            },
        requestGate: requestGate,
      );
      final harness = _SettingsHarness(permissionsPort: port);

      final first = harness.controller.requestPermission(
        PlatformPermissionKind.microphone,
      );
      expect(
        harness.controller.state.permissionOperationPhase,
        PermissionOperationPhase.requesting,
      );
      expect(
        harness.controller.state.activePermissionKind,
        PlatformPermissionKind.microphone,
      );

      final duplicate = await harness.controller.requestPermission(
        PlatformPermissionKind.camera,
      );
      expect(duplicate, isFalse);
      expect(port.requestedKinds, <PlatformPermissionKind>[
        PlatformPermissionKind.microphone,
      ]);

      requestGate.complete();
      expect(await first, isTrue);
      expect(
        harness.controller.state.permissionOperationPhase,
        PermissionOperationPhase.idle,
      );
      expect(harness.controller.state.activePermissionKind, isNull);
    });

    test('opening system settings requires acknowledgement', () async {
      final harness = _SettingsHarness(
        permissionsPort: _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        ),
      );

      await harness.controller.openPermissionSettings(
        PlatformPermissionKind.microphone,
        impactAcknowledged: false,
      );

      expect(
        harness.controller.state.permissionOpenStatus,
        PermissionOpenStatus.failed,
      );
      expect(
        harness.controller.state.permissionOpenError?.code,
        'PERMISSION_IMPACT_ACK_REQUIRED',
      );
    });

    test(
      'propagates fake open-settings success without fallback paths',
      () async {
        final port = _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        );
        final harness = _SettingsHarness(permissionsPort: port);

        await harness.controller.openPermissionSettings(
          PlatformPermissionKind.mediaLibrary,
          impactAcknowledged: true,
        );

        expect(port.openedKinds, <PlatformPermissionKind>[
          PlatformPermissionKind.mediaLibrary,
        ]);
        expect(
          harness.controller.state.permissionOpenStatus,
          PermissionOpenStatus.opened,
        );
        expect(
          harness.controller.state.lastOpenedPermission,
          PlatformPermissionKind.mediaLibrary,
        );
      },
    );

    test(
      'propagates fake open-settings failure without fallback success',
      () async {
        final harness = _SettingsHarness(
          permissionsPort: _FakePermissionsPort(
            statuses:
                const <PlatformPermissionKind, PlatformPermissionStatus>{},
            openFailure: const AppFailure(
              code: 'PLATFORM_SETTINGS_OPEN_FAILED',
              category: AppFailureCategory.permission,
              message: 'settings failed',
              userMessageKey: 'settings.permissions.openFailed',
            ),
          ),
        );

        await harness.controller.openPermissionSettings(
          PlatformPermissionKind.bluetooth,
          impactAcknowledged: true,
        );

        expect(
          harness.controller.state.permissionOpenStatus,
          PermissionOpenStatus.failed,
        );
        expect(
          harness.controller.state.permissionOpenError?.code,
          'PLATFORM_SETTINGS_OPEN_FAILED',
        );
        expect(harness.controller.state.lastOpenedPermission, isNull);
      },
    );

    test('filters developer logs until developer mode is enabled', () {
      final harness = _SettingsHarness(
        permissionsPort: _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        ),
      );
      harness.logger.log(
        const DiagnosticLogInput(
          category: DiagnosticCategory.app,
          severity: DiagnosticSeverity.info,
          safeSummary: 'Visible event',
        ),
      );
      harness.logger.log(
        const DiagnosticLogInput(
          category: DiagnosticCategory.app,
          severity: DiagnosticSeverity.debug,
          safeSummary: 'Developer event',
          developerOnly: true,
        ),
      );

      harness.controller.refreshDiagnostics();

      expect(harness.controller.state.diagnosticLogs, hasLength(1));
      expect(
        harness.controller.state.diagnosticLogs.single.safeSummary,
        'Visible event',
      );

      harness.controller.setDeveloperModeEnabled(true);

      expect(harness.controller.state.developerModeEnabled, isTrue);
      expect(harness.controller.state.diagnosticLogs, hasLength(2));
    });

    test('exports redacted in-memory diagnostics package', () async {
      final harness = _SettingsHarness(
        permissionsPort: _FakePermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{},
        ),
        performanceSnapshot: () => PerformanceSnapshot(
          capturedAt: DateTime.utc(2026, 7, 8, 8),
          frame: const <String, Object?>{'sampleCount': 3},
          runtime: const <String, Object?>{
            'route': '/v3/feed/chat/:id',
            'token': 'performance-token-secret',
          },
          tasks: const <String, Object?>{},
          database: const <String, Object?>{},
          network: const <String, Object?>{
            'url': 'https://private.example/path?token=secret',
          },
          imageCaches: const <String, Object?>{
            'decoded': <String, Object?>{'currentBytes': 1024},
          },
        ),
      );
      harness.logger.log(
        const DiagnosticLogInput(
          category: DiagnosticCategory.permission,
          severity: DiagnosticSeverity.warning,
          safeSummary: 'HTTP 500 /Users/run/private.wav',
          metadata: <String, Object?>{
            'stage': 'permission',
            'token': 'access-token-secret',
            'message': 'Native Module Error: GATT_ERROR',
          },
        ),
      );

      await harness.controller.exportDiagnostics();

      final exportState = harness.controller.state.diagnosticExportState;
      expect(exportState.status, DiagnosticExportStatus.succeeded);
      final json =
          jsonDecode(exportState.package!.jsonText) as Map<String, Object?>;
      expect(json['eventCount'], 1);
      final events = json['events']! as List<Object?>;
      final event = events.first! as Map<String, Object?>;
      expect(event['safeSummary'], 'Application operation failed');
      final metadata = event['metadata']! as Map<String, Object?>;
      expect(metadata.containsKey('token'), isFalse);
      expect(metadata['message'], 'redacted');
      final performance = json['performance']! as Map<String, Object?>;
      expect(performance['imageCaches'], isNotNull);
      expect(exportState.package!.jsonText, contains('/v3/feed/chat/:id'));
      expect(exportState.package!.jsonText, isNot(contains('private.example')));
      expect(
        exportState.package!.jsonText,
        isNot(contains('performance-token-secret')),
      );
    });
  });
}

final class _SettingsHarness {
  _SettingsHarness({
    required PlatformPermissionsPort permissionsPort,
    PerformanceSnapshot Function()? performanceSnapshot,
  }) : database = AppDatabase() {
    dao = DiagnosticLogDao(database);
    logger = DiagnosticLogger(dao: dao, now: () => DateTime.utc(2026, 7, 8, 8));
    controller = SettingsController(
      permissionsPort: permissionsPort,
      diagnosticLogDao: dao,
      diagnosticLogger: logger,
      diagnosticExportService: DiagnosticExportService(
        dao: dao,
        performanceSnapshot: performanceSnapshot,
        now: () => DateTime.utc(2026, 7, 8, 8, 1),
      ),
      now: () => DateTime.utc(2026, 7, 8, 8, 2),
    );
  }

  final AppDatabase database;
  late final DiagnosticLogDao dao;
  late final DiagnosticLogger logger;
  late final SettingsController controller;
}

final class _FakePermissionsPort implements PlatformPermissionsPort {
  _FakePermissionsPort({
    required this.statuses,
    this.requestedStatuses,
    this.openFailure,
    this.requestGate,
  });

  final Map<PlatformPermissionKind, PlatformPermissionStatus> statuses;
  final Map<PlatformPermissionKind, PlatformPermissionStatus>?
  requestedStatuses;
  final AppFailure? openFailure;
  final Completer<void>? requestGate;
  final openedKinds = <PlatformPermissionKind>[];
  final requestedKinds = <PlatformPermissionKind>[];

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      buildPermissionSummaryRows(statuses),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    requestedKinds.addAll(kinds);
    await requestGate?.future;
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      buildPermissionSummaryRows(requestedStatuses ?? statuses),
    );
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    if (!impactAcknowledged) {
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
        const AppFailure(
          code: 'PERMISSION_IMPACT_ACK_REQUIRED',
          category: AppFailureCategory.permission,
          message: 'Permission impact acknowledgement is required',
          userMessageKey: 'settings.permissions.ackRequired',
        ),
      );
    }
    final failure = openFailure;
    if (failure != null) {
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
        failure,
      );
    }
    openedKinds.add(kind);
    return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
      PermissionSettingsOpenReceipt(
        kind: kind,
        opened: true,
        impactText: buildPermissionImpactText(kind),
      ),
    );
  }
}
