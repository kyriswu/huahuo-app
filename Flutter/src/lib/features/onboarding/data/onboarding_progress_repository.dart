import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../chat/domain/chat_models.dart';

const onboardingBusinessMode = 'business';
const onboardingNoBusinessMode = 'no_business';

final class OnboardingProgressSnapshot {
  const OnboardingProgressSnapshot({
    this.mode = '',
    this.stepIndex = 0,
    this.answers = const <String, Object>{},
    this.deferredAt,
    this.acceptedRun,
  });

  final String mode;
  final int stepIndex;
  final Map<String, Object> answers;
  final DateTime? deferredAt;
  final OnboardingAcceptedRun? acceptedRun;

  bool get isDeferred => deferredAt != null;

  OnboardingProgressSnapshot copyWith({
    String? mode,
    int? stepIndex,
    Map<String, Object>? answers,
    Object? deferredAt = _unchanged,
    Object? acceptedRun = _unchanged,
  }) {
    return OnboardingProgressSnapshot(
      mode: mode ?? this.mode,
      stepIndex: stepIndex ?? this.stepIndex,
      answers: answers ?? this.answers,
      deferredAt: deferredAt == _unchanged
          ? this.deferredAt
          : deferredAt as DateTime?,
      acceptedRun: acceptedRun == _unchanged
          ? this.acceptedRun
          : acceptedRun as OnboardingAcceptedRun?,
    );
  }
}

enum OnboardingAcceptedRunLifecycle { running, finalizing, succeeded, failed }

extension OnboardingAcceptedRunLifecycleWire on OnboardingAcceptedRunLifecycle {
  String get wireName => name;
}

OnboardingAcceptedRunLifecycle? onboardingAcceptedRunLifecycleFromWire(
  Object? value,
) => switch (value) {
  null || 'running' => OnboardingAcceptedRunLifecycle.running,
  'finalizing' => OnboardingAcceptedRunLifecycle.finalizing,
  'succeeded' => OnboardingAcceptedRunLifecycle.succeeded,
  'failed' => OnboardingAcceptedRunLifecycle.failed,
  _ => null,
};

enum OnboardingAcceptedRunReportSource { agentReply, workspaceProfile }

extension OnboardingAcceptedRunReportSourceWire
    on OnboardingAcceptedRunReportSource {
  String get wireName => switch (this) {
    OnboardingAcceptedRunReportSource.agentReply => 'agent_reply',
    OnboardingAcceptedRunReportSource.workspaceProfile => 'workspace_profile',
  };
}

OnboardingAcceptedRunReportSource? onboardingAcceptedRunReportSourceFromWire(
  Object? value,
) => switch (value) {
  null || 'agent_reply' => OnboardingAcceptedRunReportSource.agentReply,
  'workspace_profile' => OnboardingAcceptedRunReportSource.workspaceProfile,
  _ => null,
};

final class OnboardingAcceptedRun {
  const OnboardingAcceptedRun({
    required this.threadId,
    required this.agentRunId,
    required this.taskId,
    required this.messageId,
    required this.status,
    this.lifecycle = OnboardingAcceptedRunLifecycle.running,
    this.failureCode,
    this.updatedAt,
    this.completedAt,
    this.workspaceId,
    this.attemptId,
    this.registrationErrorCode,
    this.reportSource = OnboardingAcceptedRunReportSource.agentReply,
  });

  final String threadId;
  final String agentRunId;
  final String taskId;
  final String messageId;
  final String status;
  final OnboardingAcceptedRunLifecycle lifecycle;
  final String? failureCode;
  final DateTime? updatedAt;
  final DateTime? completedAt;
  final String? workspaceId;
  final String? attemptId;
  final String? registrationErrorCode;
  final OnboardingAcceptedRunReportSource reportSource;

  bool get isBackendRegistered =>
      workspaceId?.isNotEmpty == true && attemptId?.isNotEmpty == true;

  bool isRegisteredFor(String? workspace) =>
      isBackendRegistered && workspaceId == workspace;

  bool get isTerminal =>
      lifecycle == OnboardingAcceptedRunLifecycle.succeeded ||
      lifecycle == OnboardingAcceptedRunLifecycle.failed;

  bool get needsFinalizationReconciliation =>
      lifecycle == OnboardingAcceptedRunLifecycle.failed &&
      failureCode == 'INITIAL_POSITIONING_INVALID';

  OnboardingAcceptedRun copyWith({
    OnboardingAcceptedRunLifecycle? lifecycle,
    Object? failureCode = _unchanged,
    Object? updatedAt = _unchanged,
    Object? completedAt = _unchanged,
    String? workspaceId,
    String? attemptId,
    Object? registrationErrorCode = _unchanged,
    OnboardingAcceptedRunReportSource? reportSource,
  }) {
    return OnboardingAcceptedRun(
      threadId: threadId,
      agentRunId: agentRunId,
      taskId: taskId,
      messageId: messageId,
      status: status,
      workspaceId: workspaceId ?? this.workspaceId,
      attemptId: attemptId ?? this.attemptId,
      registrationErrorCode: registrationErrorCode == _unchanged
          ? this.registrationErrorCode
          : registrationErrorCode as String?,
      reportSource: reportSource ?? this.reportSource,
      lifecycle: lifecycle ?? this.lifecycle,
      failureCode: failureCode == _unchanged
          ? this.failureCode
          : failureCode as String?,
      updatedAt: updatedAt == _unchanged
          ? this.updatedAt
          : updatedAt as DateTime?,
      completedAt: completedAt == _unchanged
          ? this.completedAt
          : completedAt as DateTime?,
    );
  }
}

const _unchanged = Object();

final class OnboardingProgressRepository {
  OnboardingProgressRepository({
    required AppPreferencesDao dao,
    this.workspaceId,
  }) : _dao = dao;

  final String? workspaceId;

  static const _schemaVersion = 4;
  static const _keyPrefix = 'onboarding.progress.v1.';

  final AppPreferencesDao _dao;

  OnboardingProgressSnapshot load(String userId) {
    final key = _preferenceKey(userId);
    if (key == null) return const OnboardingProgressSnapshot();
    final scoped = _dao.readValue(key);
    final encoded =
        scoped ??
        (workspaceId == null
            ? null
            : _dao.readValue(_preferenceKey(userId, legacy: true)!));
    if (encoded == null) return const OnboardingProgressSnapshot();
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          (value['version'] != 1 &&
              value['version'] != 2 &&
              value['version'] != 3 &&
              value['version'] != _schemaVersion)) {
        return const OnboardingProgressSnapshot();
      }
      final mode = value['mode'];
      final stepIndex = value['stepIndex'];
      final answers = _parseAnswers(value['answers']);
      final rawDeferredAt = value['deferredAt'];
      final deferredAt = rawDeferredAt is String
          ? DateTime.tryParse(rawDeferredAt)?.toUtc()
          : null;
      final acceptedRun = _acceptedRun(value['acceptedRun']);
      if (workspaceId != null &&
          acceptedRun?.workspaceId != null &&
          acceptedRun!.workspaceId != workspaceId)
        return const OnboardingProgressSnapshot();
      if (mode is! String ||
          stepIndex is! int ||
          answers == null ||
          (rawDeferredAt != null && deferredAt == null) ||
          (value['acceptedRun'] != null && acceptedRun == null) ||
          !_isValidProgress(
            mode: mode,
            stepIndex: stepIndex,
            answers: answers,
          )) {
        return const OnboardingProgressSnapshot();
      }
      return OnboardingProgressSnapshot(
        mode: mode,
        stepIndex: stepIndex,
        answers: Map<String, Object>.unmodifiable(answers),
        deferredAt: deferredAt,
        acceptedRun: acceptedRun,
      );
    } on FormatException {
      return const OnboardingProgressSnapshot();
    } on TypeError {
      return const OnboardingProgressSnapshot();
    }
  }

  bool save({
    required String userId,
    required OnboardingProgressSnapshot snapshot,
    required DateTime updatedAt,
  }) {
    final key = _preferenceKey(userId);
    if (key == null ||
        !_isValidProgress(
          mode: snapshot.mode,
          stepIndex: snapshot.stepIndex,
          answers: snapshot.answers,
        )) {
      return false;
    }
    _dao.upsertValue(
      preferenceKey: key,
      value: jsonEncode(<String, Object?>{
        'version': _schemaVersion,
        'mode': snapshot.mode,
        'stepIndex': snapshot.stepIndex,
        'answers': snapshot.answers,
        'deferredAt': snapshot.deferredAt?.toUtc().toIso8601String(),
        if (snapshot.acceptedRun case final run?)
          'acceptedRun': <String, Object?>{
            'threadId': run.threadId,
            'agentRunId': run.agentRunId,
            'taskId': run.taskId,
            'messageId': run.messageId,
            'status': run.status,
            'lifecycle': run.lifecycle.wireName,
            'reportSource': run.reportSource.wireName,
            if (run.workspaceId != null) 'workspaceId': run.workspaceId,
            if (run.attemptId != null) 'attemptId': run.attemptId,
            if (run.registrationErrorCode != null)
              'registrationErrorCode': run.registrationErrorCode,
            if (run.failureCode != null) 'failureCode': run.failureCode,
            if (run.updatedAt != null)
              'updatedAt': run.updatedAt!.toUtc().toIso8601String(),
            if (run.completedAt != null)
              'completedAt': run.completedAt!.toUtc().toIso8601String(),
          },
      }),
      updatedAt: updatedAt.toUtc().toIso8601String(),
    );
    return true;
  }

  bool clear(String userId) {
    final key = _preferenceKey(userId);
    return key != null && _dao.deleteValue(key);
  }

  String? _preferenceKey(String userId, {bool legacy = false}) {
    final normalized = userId.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(normalized)) {
      return null;
    }
    final digest = base64Url
        .encode(
          sha256
              .convert(
                utf8.encode(
                  workspaceId == null || legacy
                      ? normalized
                      : '$normalized\u0000$workspaceId',
                ),
              )
              .bytes,
        )
        .replaceAll('=', '');
    return '$_keyPrefix$digest';
  }
}

OnboardingAcceptedRun? _acceptedRun(Object? value) {
  if (value is! Map) return null;
  String? text(Object? candidate, {int maximum = 160}) {
    if (candidate is! String) return null;
    final normalized = candidate.trim();
    return normalized.isEmpty || normalized.length > maximum
        ? null
        : normalized;
  }

  bool identifier(String? candidate) =>
      candidate != null &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(candidate);
  final threadId = text(value['threadId']);
  final rawAgentRunId = value['agentRunId'];
  final agentRunId = rawAgentRunId is String ? rawAgentRunId.trim() : null;
  final taskId = text(value['taskId']);
  final messageId = text(value['messageId']);
  final status = text(value['status'], maximum: 80);
  final lifecycle = onboardingAcceptedRunLifecycleFromWire(value['lifecycle']);
  final reportSource = onboardingAcceptedRunReportSourceFromWire(
    value['reportSource'],
  );
  final workspaceId = text(value['workspaceId']);
  final attemptId = text(value['attemptId'], maximum: 512);
  final registrationErrorCode = text(value['registrationErrorCode']);
  final failureCode = value['failureCode'] == null
      ? null
      : text(value['failureCode'], maximum: 160);
  final updatedAt = value['updatedAt'] == null
      ? null
      : _safeDate(value['updatedAt']);
  final completedAt = value['completedAt'] == null
      ? null
      : _safeDate(value['completedAt']);
  if (!identifier(threadId) ||
      agentRunId == null ||
      !isSafeAgentRunIdentifier(agentRunId) ||
      !identifier(taskId) ||
      !identifier(messageId) ||
      status == null ||
      lifecycle == null ||
      reportSource == null ||
      (value['workspaceId'] != null && !identifier(workspaceId)) ||
      (value['attemptId'] != null &&
          (workspaceId == null ||
              attemptId == null ||
              !RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$',
              ).hasMatch(attemptId))) ||
      (value['registrationErrorCode'] != null &&
          registrationErrorCode == null) ||
      (value['failureCode'] != null && failureCode == null) ||
      (value['updatedAt'] != null && updatedAt == null) ||
      (value['completedAt'] != null && completedAt == null) ||
      (reportSource == OnboardingAcceptedRunReportSource.workspaceProfile &&
          (lifecycle != OnboardingAcceptedRunLifecycle.succeeded ||
              workspaceId == null ||
              attemptId == null))) {
    return null;
  }
  return OnboardingAcceptedRun(
    threadId: threadId!,
    agentRunId: agentRunId,
    taskId: taskId!,
    messageId: messageId!,
    status: status,
    lifecycle: lifecycle,
    workspaceId: workspaceId,
    attemptId: attemptId,
    registrationErrorCode: registrationErrorCode,
    reportSource: reportSource,
    failureCode: failureCode,
    updatedAt: updatedAt,
    completedAt: completedAt,
  );
}

DateTime? _safeDate(Object? value) {
  final raw = value is String && value.length <= 64 ? value : null;
  return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

Map<String, Object>? _parseAnswers(Object? value) {
  if (value is! Map<String, dynamic> ||
      value.length > _allowedAnswerIds.length) {
    return null;
  }
  final answers = <String, Object>{};
  for (final entry in value.entries) {
    if (!_allowedAnswerIds.contains(entry.key)) return null;
    final answer = entry.value;
    if (answer is String && _isValidAnswerText(answer)) {
      answers[entry.key] = answer;
      continue;
    }
    if (answer is List &&
        answer.isNotEmpty &&
        answer.length <= 8 &&
        answer.every((item) => item is String && _isValidAnswerText(item))) {
      answers[entry.key] = List<String>.unmodifiable(answer.cast<String>());
      continue;
    }
    return null;
  }
  return answers;
}

bool _isValidProgress({
  required String mode,
  required int stepIndex,
  required Map<String, Object> answers,
}) {
  final maximumStep = switch (mode) {
    '' => 0,
    onboardingBusinessMode => 3,
    onboardingNoBusinessMode => 6,
    _ => -1,
  };
  if (maximumStep < 0 || stepIndex < 0 || stepIndex > maximumStep) return false;
  if (mode.isEmpty && answers.isNotEmpty) return false;
  if (answers.length > _allowedAnswerIds.length) return false;
  return answers.entries.every((entry) {
    if (!_allowedAnswerIds.contains(entry.key)) return false;
    final value = entry.value;
    return value is String
        ? _isValidAnswerText(value)
        : value is List<String> &&
              value.isNotEmpty &&
              value.length <= 8 &&
              value.every(_isValidAnswerText);
  });
}

bool _isValidAnswerText(String value) {
  final normalized = value.trim();
  return normalized.isNotEmpty &&
      normalized.length <= 240 &&
      !normalized.contains(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'));
}

const _allowedAnswerIds = <String>{
  'customerScope',
  'productDescription',
  'desiredCustomer',
  'customerTalkValue',
  'userProfile',
  'direction',
  'strengths',
  'dailyConcerns',
  'readingHabit',
  'workHistory',
  'schoolMajor',
};
