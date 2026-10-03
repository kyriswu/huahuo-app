import 'dart:convert';

import '../api/api_envelope.dart';
import '../database/diagnostic_log_dao.dart';
import '../performance/performance_snapshot.dart';

final class DiagnosticExportPackage {
  const DiagnosticExportPackage({
    required this.fileName,
    required this.contentType,
    required this.generatedAt,
    required this.eventCount,
    required this.categories,
    required this.privacyNotice,
    required this.jsonText,
  });

  final String fileName;
  final String contentType;
  final DateTime generatedAt;
  final int eventCount;
  final List<String> categories;
  final String privacyNotice;
  final String jsonText;
}

final class DiagnosticExportResult {
  const DiagnosticExportResult._({required this.ok, this.package, this.error});

  factory DiagnosticExportResult.success(DiagnosticExportPackage package) {
    return DiagnosticExportResult._(ok: true, package: package);
  }

  factory DiagnosticExportResult.failure(AppFailure error) {
    return DiagnosticExportResult._(ok: false, error: error);
  }

  final bool ok;
  final DiagnosticExportPackage? package;
  final AppFailure? error;
}

final class DiagnosticExportService {
  DiagnosticExportService({
    required DiagnosticLogDao dao,
    PerformanceSnapshot Function()? performanceSnapshot,
    DateTime Function()? now,
  }) : _dao = dao,
       _performanceSnapshot = performanceSnapshot,
       _now = now ?? DateTime.now;

  final DiagnosticLogDao _dao;
  final PerformanceSnapshot Function()? _performanceSnapshot;
  final DateTime Function() _now;

  DiagnosticExportResult createPackage({
    bool includeDeveloperOnly = false,
    int limit = 200,
  }) {
    try {
      final generatedAt = _now().toUtc();
      final events = _dao.query(
        DiagnosticLogQuery(
          includeDeveloperOnly: includeDeveloperOnly,
          limit: limit,
        ),
      );
      final categories = events.map((event) => event.category).toSet().toList()
        ..sort();
      final performance = _performanceSnapshot?.call();
      final payload = <String, Object?>{
        'schema': 'huahuo.diagnostics.v1',
        'generatedAt': generatedAt.toIso8601String(),
        'eventCount': events.length,
        'categories': categories,
        'privacyNotice': diagnosticPrivacyNotice,
        'events': events.map(_eventToJson).toList(growable: false),
        if (performance != null) 'performance': performance.toJson(),
      };
      return DiagnosticExportResult.success(
        DiagnosticExportPackage(
          fileName: 'huahuo-diagnostics-${_compactTimestamp(generatedAt)}.json',
          contentType: 'application/json',
          generatedAt: generatedAt,
          eventCount: events.length,
          categories: List<String>.unmodifiable(categories),
          privacyNotice: diagnosticPrivacyNotice,
          jsonText: jsonEncode(payload),
        ),
      );
    } catch (error) {
      return DiagnosticExportResult.failure(
        AppFailure(
          code: 'DIAGNOSTIC_EXPORT_FAILED',
          category: AppFailureCategory.storage,
          message: 'Diagnostic export failed',
          userMessageKey: 'settings.diagnostics.exportFailed',
          isRetryable: true,
          recoveryActions: const <String>['retry'],
          cause: error,
        ),
      );
    }
  }

  Map<String, Object?> _eventToJson(DiagnosticLogRecord event) {
    return <String, Object?>{
      'eventId': event.eventId,
      'createdAt': event.createdAt.toIso8601String(),
      'category': event.category,
      'severity': event.severity.wireName,
      'correlationId': event.correlationId,
      'safeSummary': event.safeSummary,
      'metadata': event.redactedMetadata,
      'developerOnly': event.developerOnly,
    };
  }

  String _compactTimestamp(DateTime value) {
    return value
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
  }
}

const diagnosticPrivacyNotice = '诊断信息不包含音频内容、token、Wi-Fi 密码、本地路径或隐私原文。';
