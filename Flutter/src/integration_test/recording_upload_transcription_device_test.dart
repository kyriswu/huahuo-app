import 'package:huahuoai_app/app/di/diagnostics_providers.dart';
import 'dart:io';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _enabled = bool.fromEnvironment(
  'HUAHUO_RECORDING_E2E',
  defaultValue: false,
);
const _e2ePhone = String.fromEnvironment('HUAHUO_RECORDING_E2E_PHONE');
const _e2eCode = String.fromEnvironment('HUAHUO_RECORDING_E2E_CODE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'imports and uploads a phone recording and receives a transcript',
    (tester) async {
      final startedAt = DateTime.now().toUtc();
      final container = await _launchAuthenticatedApp(tester);
      final repository = container.read(localRecordingRepositoryProvider);
      final documents = await getApplicationDocumentsDirectory();
      final sourceFile = File('${documents.path}/huahuo-recording-e2e.m4a');
      expect(
        await sourceFile.exists(),
        isTrue,
        reason:
            'Inject huahuo-recording-e2e.m4a into the App Documents folder.',
      );

      final runId = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
      final imported = await repository.importPickedRecording(
        PickedAudioFile(
          pickerRef: 'device-e2e-$runId',
          displayName: 'device-asr-e2e-$runId.m4a',
          mimeType: 'audio/mp4',
          sizeBytes: await sourceFile.length(),
          durationSeconds: 10,
          recordedAt: DateTime.now().toUtc(),
          sourcePath: sourceFile.path,
          sourceIdentifier: 'device-e2e-$runId',
        ),
      );
      expect(imported.ok, isTrue, reason: imported.error?.code);
      final item = imported.value!;

      final upload = container.read(recordingUploadControllerProvider);
      final observedStages = <RecordingFileJobStatus?>[];
      void observeUpload() {
        final status = upload.state.status;
        if (observedStages.isEmpty || observedStages.last != status) {
          observedStages.add(status);
          debugPrint(
            '[RecordingDeviceE2E] uploadStage=${status?.name ?? 'idle'}',
          );
        }
      }

      upload.addListener(observeUpload);
      final created = await upload.uploadLocalRecording(
        item: item,
        sourceScene: 'raw_material',
        source: 'local_upload',
        title: item.displayName,
      );
      upload.removeListener(observeUpload);
      expect(created, isNotNull, reason: upload.state.lastErrorCode);
      expect(upload.state.status, RecordingFileJobStatus.processing);
      final recordingId = created!.recording.recordingId;
      debugPrint(
        '[RecordingDeviceE2E] uploadCompleted recordingId=$recordingId',
      );

      final detail = await _waitForFinalTranscript(
        tester,
        api: container.read(recordingApiProvider),
        recordingId: recordingId,
      );
      expect(detail.hasFinalTranscriptFact, isTrue);
      expect(detail.finalTranscript?.trim(), isNotEmpty);
      debugPrint(
        '[RecordingDeviceE2E] transcriptionCompleted '
        'status=${detail.recording.status.name} '
        'textLength=${detail.finalTranscript!.trim().length}',
      );

      final draftId = upload.state.activeDraft!.draftId;
      final correlationId = 'recording-upload-$draftId';
      final diagnostics = container
          .read(diagnosticLogDaoProvider)
          .query(
            DiagnosticLogQuery(
              since: startedAt,
              categories: const <String>['upload'],
              includeDeveloperOnly: true,
              limit: 100,
            ),
          )
          .where((event) => event.correlationId == correlationId)
          .toList(growable: false);
      final summaries = diagnostics.map((event) => event.safeSummary).toSet();
      for (final expected in const <String>{
        'recording_upload_requestingToken_started',
        'recording_upload_uploadingObject_started',
        'recording_upload_completingUpload_started',
        'recording_upload_creatingRecording_started',
        'recording_upload_persistingLocalLink_started',
        'recording_upload_asrQueued_succeeded',
      }) {
        expect(summaries, contains(expected));
      }
      final diagnosticText = diagnostics
          .map(
            (event) =>
                '${event.safeSummary} ${event.correlationId} '
                '${event.redactedMetadata}',
          )
          .join('\n');
      for (final forbidden in const <String>[
        '/private/',
        'file://',
        'http://',
        'https://',
        'Bearer ',
        'accessToken',
        'signature=',
        'base64',
      ]) {
        expect(diagnosticText, isNot(contains(forbidden)));
      }
      debugPrint(
        '[RecordingDeviceE2E] diagnosticsVerified events=${diagnostics.length}',
      );
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<ProviderContainer> _launchAuthenticatedApp(WidgetTester tester) async {
  await app.main();
  for (var attempt = 0; attempt < 80; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    if (find.byType(Scaffold).evaluate().isNotEmpty) break;
  }
  expect(find.byType(Scaffold), findsWidgets);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  );
  for (var attempt = 0; attempt < 30; attempt++) {
    if (container.read(sessionStoreProvider).state.authState ==
        SessionAuthState.authenticated) {
      return container;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }

  expect(
    _e2ePhone,
    isNotEmpty,
    reason: 'Provide HUAHUO_RECORDING_E2E_PHONE for an anonymous device.',
  );
  expect(
    _e2eCode,
    isNotEmpty,
    reason: 'Provide HUAHUO_RECORDING_E2E_CODE for an anonymous device.',
  );
  final auth = container.read(authControllerProvider);
  auth.setPhone(_e2ePhone);
  await auth.sendSmsCode();
  debugPrint(
    '[RecordingDeviceE2E] smsTicket '
    'outcome=${auth.state.smsRequestId == null ? 'failed' : 'succeeded'} '
    'error=${auth.state.lastErrorCode ?? 'none'}',
  );
  if (auth.state.smsRequestId == null) {
    final probe = await container
        .read(authApiProvider)
        .sendSmsCode(
          phone: _e2ePhone,
          correlationId: 'recording-e2e-auth-probe',
        );
    final cause = probe.error?.cause;
    debugPrint(
      '[RecordingDeviceE2E] authTransportProbe '
      'outcome=${probe.ok ? 'succeeded' : 'failed'} '
      'error=${probe.error?.code ?? 'none'} '
      'causeType=${cause.runtimeType} '
      'cause=${_boundedNetworkCause(cause)}',
    );
  }
  expect(auth.state.smsRequestId, isNotNull, reason: auth.state.lastErrorCode);
  auth.setCode(_e2eCode);
  auth.setAgreementAccepted(true);
  await auth.login();
  debugPrint(
    '[RecordingDeviceE2E] backendLogin '
    'outcome=${container.read(sessionStoreProvider).state.authState.name} '
    'error=${auth.state.lastErrorCode ?? 'none'}',
  );
  expect(
    container.read(sessionStoreProvider).state.authState,
    SessionAuthState.authenticated,
    reason: auth.state.lastErrorCode,
  );
  debugPrint('[RecordingDeviceE2E] backendSessionEstablished');
  return container;
}

String _boundedNetworkCause(Object? cause) {
  if (cause == null) return 'none';
  final redacted = cause
      .toString()
      .replaceAll(
        RegExp(r'Bearer\s+\S+', caseSensitive: false),
        'Bearer <redacted>',
      )
      .replaceAll(
        RegExp(r'(accessToken|signature|code)=[^&\s]+', caseSensitive: false),
        r'$1=<redacted>',
      );
  return redacted.length <= 300 ? redacted : redacted.substring(0, 300);
}

Future<RecordingDetail> _waitForFinalTranscript(
  WidgetTester tester, {
  required RecordingApiPort api,
  required String recordingId,
}) async {
  RecordingDetail? latest;
  String? lastError;
  for (var attempt = 0; attempt < 90; attempt++) {
    final result = await api.getRecordingDetail(recordingId);
    if (result.ok && result.data != null) {
      latest = result.data;
      if (latest!.hasFinalTranscriptFact) return latest;
      if (latest.isTerminal) break;
    } else {
      lastError = result.error?.code;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
  }
  fail(
    'Final transcript did not complete: '
    'status=${latest?.recording.status.name} error=$lastError',
  );
}
