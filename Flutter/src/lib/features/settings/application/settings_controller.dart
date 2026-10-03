import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_export_service.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/native/platform_permissions_port.dart';

// resident-provider: Preserves the settings controller state machine across route transitions.
final settingsControllerProvider = ChangeNotifierProvider<SettingsController>((
  ref,
) {
  return SettingsController.defaults();
});

final class SettingsController extends ChangeNotifier {
  SettingsController({
    required PlatformPermissionsPort permissionsPort,
    required DiagnosticLogDao diagnosticLogDao,
    required DiagnosticLogger diagnosticLogger,
    required DiagnosticExportService diagnosticExportService,
    Future<bool> Function()? requestNotificationPermission,
    DateTime Function()? now,
  }) : _permissionsPort = permissionsPort,
       _diagnosticLogDao = diagnosticLogDao,
       _diagnosticLogger = diagnosticLogger,
       _diagnosticExportService = diagnosticExportService,
       _requestNotificationPermission = requestNotificationPermission,
       _now = now ?? DateTime.now,
       _state = SettingsState.initial();

  factory SettingsController.defaults() {
    final database = AppDatabase();
    final dao = DiagnosticLogDao(database);
    final logger = DiagnosticLogger(dao: dao);
    return SettingsController(
      permissionsPort: const MethodChannelPlatformPermissionsPort(),
      diagnosticLogDao: dao,
      diagnosticLogger: logger,
      diagnosticExportService: DiagnosticExportService(dao: dao),
    );
  }

  final PlatformPermissionsPort _permissionsPort;
  final DiagnosticLogDao _diagnosticLogDao;
  final DiagnosticLogger _diagnosticLogger;
  final DiagnosticExportService _diagnosticExportService;
  final Future<bool> Function()? _requestNotificationPermission;
  final DateTime Function() _now;
  SettingsState _state;
  bool _refreshPermissionsWhenIdle = false;

  SettingsState get state => _state;

  SettingsState buildInitialState() => _state;

  Future<void> load() async {
    await refreshPermissions();
    refreshDiagnostics();
  }

  Future<void> refreshPermissions() async {
    if (_state.permissionOperationPhase != PermissionOperationPhase.idle) {
      _refreshPermissionsWhenIdle = true;
      return;
    }
    _setState(
      _state.copyWith(
        permissionOperationPhase: PermissionOperationPhase.refreshing,
        activePermissionKind: null,
      ),
    );
    try {
      await _loadPermissionRows();
    } finally {
      _endPermissionOperation();
    }
  }

  Future<void> _loadPermissionRows() async {
    _setState(
      _state.copyWith(
        permissionLoadStatus: SettingsLoadStatus.loading,
        permissionError: null,
      ),
    );
    final result = await _permissionsPort.loadPermissionSummary();
    if (result.ok && result.value != null) {
      _setState(
        _state.copyWith(
          permissionRows: result.value!,
          permissionLoadStatus: SettingsLoadStatus.loaded,
          permissionError: null,
        ),
      );
      return;
    }

    final failure =
        result.error ?? _settingsFailure('PERMISSION_STATUS_FAILED');
    _diagnosticLogger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.permission,
        severity: DiagnosticSeverity.warning,
        safeSummary: failure.message,
        metadata: failure.metadata,
        createdAt: _now().toUtc(),
      ),
    );
    _setState(
      _state.copyWith(
        permissionRows: buildPermissionSummaryRows(
          const {},
          fallbackStatus: PlatformPermissionStatus.unavailable,
        ),
        permissionLoadStatus: SettingsLoadStatus.failed,
        permissionError: failure,
      ),
    );
  }

  Future<bool> requestPermission(PlatformPermissionKind kind) async {
    if (!_beginPermissionOperation(kind, PermissionOperationPhase.requesting)) {
      return false;
    }
    _setState(
      _state.copyWith(
        permissionLoadStatus: SettingsLoadStatus.loading,
        permissionError: null,
      ),
    );
    try {
      if (kind == PlatformPermissionKind.notification &&
          _requestNotificationPermission != null) {
        final requested = await _requestNotificationPermission();
        await _loadPermissionRows();
        return requested;
      }
      final result = await _permissionsPort.requestPermissions(
        <PlatformPermissionKind>{kind},
      );
      if (result.ok && result.value != null) {
        _diagnosticLogger.log(
          DiagnosticLogInput(
            category: DiagnosticCategory.permission,
            severity: DiagnosticSeverity.info,
            safeSummary: 'Permission requested',
            metadata: <String, Object?>{'kind': kind.wireName},
            createdAt: _now().toUtc(),
          ),
        );
        _setState(
          _state.copyWith(
            permissionRows: result.value!,
            permissionLoadStatus: SettingsLoadStatus.loaded,
            permissionError: null,
          ),
        );
        return true;
      }

      final failure =
          result.error ?? _settingsFailure('PERMISSION_REQUEST_FAILED');
      _diagnosticLogger.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.permission,
          severity: DiagnosticSeverity.warning,
          safeSummary: failure.message,
          metadata: <String, Object?>{
            ...failure.metadata,
            'kind': kind.wireName,
          },
          createdAt: _now().toUtc(),
        ),
      );
      _setState(
        _state.copyWith(
          permissionLoadStatus: SettingsLoadStatus.failed,
          permissionError: failure,
        ),
      );
      return false;
    } finally {
      _endPermissionOperation();
    }
  }

  Future<void> openPermissionSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    if (!_beginPermissionOperation(
      kind,
      PermissionOperationPhase.openingSettings,
    )) {
      return;
    }
    _setState(
      _state.copyWith(
        permissionOpenStatus: PermissionOpenStatus.opening,
        permissionOpenError: null,
        lastOpenedPermission: null,
      ),
    );
    try {
      final result = await _permissionsPort.openAppSettings(
        kind,
        impactAcknowledged: impactAcknowledged,
      );
      if (result.ok && result.value != null) {
        _diagnosticLogger.log(
          DiagnosticLogInput(
            category: DiagnosticCategory.permission,
            severity: DiagnosticSeverity.info,
            safeSummary: 'Permission settings opened',
            metadata: <String, Object?>{'kind': kind.wireName},
            createdAt: _now().toUtc(),
          ),
        );
        _setState(
          _state.copyWith(
            permissionOpenStatus: PermissionOpenStatus.opened,
            lastOpenedPermission: kind,
            permissionOpenError: null,
          ),
        );
        return;
      }

      final failure =
          result.error ?? _settingsFailure('PERMISSION_OPEN_FAILED');
      _diagnosticLogger.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.permission,
          severity: DiagnosticSeverity.warning,
          safeSummary: failure.message,
          metadata: <String, Object?>{
            ...failure.metadata,
            'kind': kind.wireName,
          },
          createdAt: _now().toUtc(),
        ),
      );
      _setState(
        _state.copyWith(
          permissionOpenStatus: PermissionOpenStatus.failed,
          permissionOpenError: failure,
          lastOpenedPermission: null,
        ),
      );
    } finally {
      _endPermissionOperation();
    }
  }

  bool _beginPermissionOperation(
    PlatformPermissionKind kind,
    PermissionOperationPhase phase,
  ) {
    if (_state.permissionOperationPhase != PermissionOperationPhase.idle) {
      return false;
    }
    _setState(
      _state.copyWith(
        permissionOperationPhase: phase,
        activePermissionKind: kind,
      ),
    );
    return true;
  }

  void _endPermissionOperation() {
    _setState(
      _state.copyWith(
        permissionOperationPhase: PermissionOperationPhase.idle,
        activePermissionKind: null,
      ),
    );
    if (_refreshPermissionsWhenIdle) {
      _refreshPermissionsWhenIdle = false;
      unawaited(refreshPermissions());
    }
  }

  void setDeveloperModeEnabled(bool enabled) {
    _setState(_state.copyWith(developerModeEnabled: enabled));
    refreshDiagnostics();
  }

  void setDailyReminderEnabled(bool enabled) {
    _setState(_state.copyWith(dailyReminderEnabled: enabled));
  }

  void setDailyReminderSchedule(DailyReminderSchedule schedule) {
    _setState(_state.copyWith(dailyReminderSchedule: schedule));
  }

  void setDailyReminderMinutes(int minutes) {
    _setState(
      _state.copyWith(dailyReminderMinutes: minutes.clamp(0, 1439).toInt()),
    );
  }

  void refreshDiagnostics() {
    final logs = _diagnosticLogDao.query(
      DiagnosticLogQuery(
        includeDeveloperOnly: _state.developerModeEnabled,
        limit: 50,
      ),
    );
    _setState(
      _state.copyWith(
        diagnosticLogs: logs,
        diagnosticSummary: DiagnosticSummary.fromLogs(logs),
      ),
    );
  }

  Future<void> exportDiagnostics() async {
    _setState(
      _state.copyWith(
        diagnosticExportState: const DiagnosticExportState.exporting(),
      ),
    );
    final result = _diagnosticExportService.createPackage(
      includeDeveloperOnly: _state.developerModeEnabled,
    );
    if (result.ok && result.package != null) {
      _diagnosticLogger.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.export,
          severity: DiagnosticSeverity.info,
          safeSummary: 'Diagnostics export package prepared',
          metadata: <String, Object?>{
            'eventCount': result.package!.eventCount,
            'contentType': result.package!.contentType,
          },
          createdAt: _now().toUtc(),
        ),
      );
      _setState(
        _state.copyWith(
          diagnosticExportState: DiagnosticExportState.succeeded(
            result.package!,
          ),
        ),
      );
      refreshDiagnostics();
      return;
    }

    final failure =
        result.error ?? _settingsFailure('DIAGNOSTIC_EXPORT_FAILED');
    _diagnosticLogger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.export,
        severity: DiagnosticSeverity.error,
        safeSummary: failure.message,
        metadata: failure.metadata,
        createdAt: _now().toUtc(),
      ),
    );
    _setState(
      _state.copyWith(
        diagnosticExportState: DiagnosticExportState.failed(failure),
      ),
    );
    refreshDiagnostics();
  }

  void clearDiagnosticLogs() {
    final cleared = _diagnosticLogDao.clear();
    _diagnosticLogger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.app,
        severity: DiagnosticSeverity.info,
        safeSummary: 'Diagnostic logs cleared',
        metadata: <String, Object?>{'cleared': cleared},
        createdAt: _now().toUtc(),
      ),
    );
    refreshDiagnostics();
  }

  void _setState(SettingsState state) {
    _state = state;
    notifyListeners();
  }

  AppFailure _settingsFailure(String code) {
    return AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Settings operation failed',
      userMessageKey: 'settings.operationFailed',
      isRetryable: true,
      recoveryActions: const <String>['retry'],
    );
  }
}

enum SettingsLoadStatus { idle, loading, loaded, failed }

enum DailyReminderSchedule { everyDay, weekdays }

extension DailyReminderScheduleLabel on DailyReminderSchedule {
  String get label => switch (this) {
    DailyReminderSchedule.everyDay => '每天',
    DailyReminderSchedule.weekdays => '工作日',
  };
}

enum PermissionOpenStatus { idle, opening, opened, failed }

enum PermissionOperationPhase { idle, refreshing, requesting, openingSettings }

enum DiagnosticExportStatus { idle, exporting, succeeded, failed }

final class DiagnosticSummary {
  const DiagnosticSummary({
    required this.eventCount,
    required this.categories,
    required this.privacyNotice,
    required this.recentIssues,
  });

  factory DiagnosticSummary.empty() {
    return const DiagnosticSummary(
      eventCount: 0,
      categories: <String>[],
      privacyNotice: diagnosticPrivacyNotice,
      recentIssues: <DiagnosticIssueSummary>[],
    );
  }

  factory DiagnosticSummary.fromLogs(List<DiagnosticLogRecord> logs) {
    final categories = logs.map((log) => log.category).toSet().toList()..sort();
    final issues = logs
        .where(
          (log) =>
              log.severity == DiagnosticSeverity.warning ||
              log.severity == DiagnosticSeverity.error,
        )
        .take(5)
        .map(
          (log) => DiagnosticIssueSummary(
            issueId: log.eventId,
            category: log.category,
            safeSummary: log.safeSummary,
            occurredAt: log.createdAt,
          ),
        )
        .toList(growable: false);
    return DiagnosticSummary(
      eventCount: logs.length,
      categories: List<String>.unmodifiable(categories),
      privacyNotice: diagnosticPrivacyNotice,
      recentIssues: List<DiagnosticIssueSummary>.unmodifiable(issues),
    );
  }

  final int eventCount;
  final List<String> categories;
  final String privacyNotice;
  final List<DiagnosticIssueSummary> recentIssues;
}

final class DiagnosticIssueSummary {
  const DiagnosticIssueSummary({
    required this.issueId,
    required this.category,
    required this.safeSummary,
    required this.occurredAt,
  });

  final String issueId;
  final String category;
  final String safeSummary;
  final DateTime occurredAt;
}

final class DiagnosticExportState {
  const DiagnosticExportState._({
    required this.status,
    this.package,
    this.error,
  });

  const DiagnosticExportState.idle()
    : this._(status: DiagnosticExportStatus.idle);

  const DiagnosticExportState.exporting()
    : this._(status: DiagnosticExportStatus.exporting);

  const DiagnosticExportState.succeeded(DiagnosticExportPackage package)
    : this._(status: DiagnosticExportStatus.succeeded, package: package);

  const DiagnosticExportState.failed(AppFailure error)
    : this._(status: DiagnosticExportStatus.failed, error: error);

  final DiagnosticExportStatus status;
  final DiagnosticExportPackage? package;
  final AppFailure? error;
}

final class SettingsState {
  const SettingsState({
    required this.diagnosticsAvailable,
    required this.developerModeEnabled,
    required this.permissionRows,
    required this.permissionLoadStatus,
    required this.permissionOpenStatus,
    required this.permissionOperationPhase,
    required this.diagnosticLogs,
    required this.diagnosticSummary,
    required this.diagnosticExportState,
    required this.dailyReminderEnabled,
    required this.dailyReminderSchedule,
    required this.dailyReminderMinutes,
    this.permissionError,
    this.permissionOpenError,
    this.lastOpenedPermission,
    this.activePermissionKind,
  });

  factory SettingsState.initial() {
    return SettingsState(
      diagnosticsAvailable: true,
      developerModeEnabled: false,
      permissionRows: buildPermissionSummaryRows(const {}),
      permissionLoadStatus: SettingsLoadStatus.idle,
      permissionOpenStatus: PermissionOpenStatus.idle,
      permissionOperationPhase: PermissionOperationPhase.idle,
      diagnosticLogs: const <DiagnosticLogRecord>[],
      diagnosticSummary: DiagnosticSummary.empty(),
      diagnosticExportState: const DiagnosticExportState.idle(),
      dailyReminderEnabled: false,
      dailyReminderSchedule: DailyReminderSchedule.weekdays,
      dailyReminderMinutes: 9 * 60,
    );
  }

  final bool diagnosticsAvailable;
  final bool developerModeEnabled;
  final List<PlatformPermissionSummary> permissionRows;
  final SettingsLoadStatus permissionLoadStatus;
  final AppFailure? permissionError;
  final PermissionOpenStatus permissionOpenStatus;
  final PermissionOperationPhase permissionOperationPhase;
  final AppFailure? permissionOpenError;
  final PlatformPermissionKind? lastOpenedPermission;
  final PlatformPermissionKind? activePermissionKind;
  final List<DiagnosticLogRecord> diagnosticLogs;
  final DiagnosticSummary diagnosticSummary;
  final DiagnosticExportState diagnosticExportState;
  final bool dailyReminderEnabled;
  final DailyReminderSchedule dailyReminderSchedule;
  final int dailyReminderMinutes;

  SettingsState copyWith({
    bool? diagnosticsAvailable,
    bool? developerModeEnabled,
    List<PlatformPermissionSummary>? permissionRows,
    SettingsLoadStatus? permissionLoadStatus,
    Object? permissionError = _unchanged,
    PermissionOpenStatus? permissionOpenStatus,
    PermissionOperationPhase? permissionOperationPhase,
    Object? permissionOpenError = _unchanged,
    Object? lastOpenedPermission = _unchanged,
    Object? activePermissionKind = _unchanged,
    List<DiagnosticLogRecord>? diagnosticLogs,
    DiagnosticSummary? diagnosticSummary,
    DiagnosticExportState? diagnosticExportState,
    bool? dailyReminderEnabled,
    DailyReminderSchedule? dailyReminderSchedule,
    int? dailyReminderMinutes,
  }) {
    return SettingsState(
      diagnosticsAvailable: diagnosticsAvailable ?? this.diagnosticsAvailable,
      developerModeEnabled: developerModeEnabled ?? this.developerModeEnabled,
      permissionRows: permissionRows ?? this.permissionRows,
      permissionLoadStatus: permissionLoadStatus ?? this.permissionLoadStatus,
      permissionError: identical(permissionError, _unchanged)
          ? this.permissionError
          : permissionError as AppFailure?,
      permissionOpenStatus: permissionOpenStatus ?? this.permissionOpenStatus,
      permissionOperationPhase:
          permissionOperationPhase ?? this.permissionOperationPhase,
      permissionOpenError: identical(permissionOpenError, _unchanged)
          ? this.permissionOpenError
          : permissionOpenError as AppFailure?,
      lastOpenedPermission: identical(lastOpenedPermission, _unchanged)
          ? this.lastOpenedPermission
          : lastOpenedPermission as PlatformPermissionKind?,
      activePermissionKind: identical(activePermissionKind, _unchanged)
          ? this.activePermissionKind
          : activePermissionKind as PlatformPermissionKind?,
      diagnosticLogs: diagnosticLogs ?? this.diagnosticLogs,
      diagnosticSummary: diagnosticSummary ?? this.diagnosticSummary,
      diagnosticExportState:
          diagnosticExportState ?? this.diagnosticExportState,
      dailyReminderEnabled: dailyReminderEnabled ?? this.dailyReminderEnabled,
      dailyReminderSchedule:
          dailyReminderSchedule ?? this.dailyReminderSchedule,
      dailyReminderMinutes: dailyReminderMinutes ?? this.dailyReminderMinutes,
    );
  }
}

const Object _unchanged = Object();
