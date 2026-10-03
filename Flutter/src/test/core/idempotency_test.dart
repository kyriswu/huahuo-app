import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/endpoint_catalog.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';

void main() {
  group('idempotency', () {
    test('required endpoint without context fails locally', () {
      final resolution = resolveIdempotencyKeyForEndpoint(
        EndpointCatalog.byId('createRecording'),
        SubmissionKeyStore.empty,
      );

      expect(resolution.ok, isFalse);
      expect(resolution.error?.code, 'IDEMPOTENCY_KEY_REQUIRED');
    });

    test('automatic retry reuses previous key for the same submission', () {
      const context = IdempotencyRequestContext(
        operation: 'create-recording',
        localDraftId: 'draft-1',
        scene: 'upload',
        generateKey: _fixedKey,
      );
      final created = resolveIdempotencyKeyForEndpoint(
        EndpointCatalog.byId('createRecording'),
        SubmissionKeyStore.empty,
        context,
      );

      final retry = resolveIdempotencyKeyForEndpoint(
        EndpointCatalog.byId('createRecording'),
        created.store,
        const IdempotencyRequestContext(
          operation: 'create-recording',
          localDraftId: 'draft-1',
          scene: 'upload',
          automaticRetry: true,
        ),
      );

      expect(created.header, 'idem-fixed');
      expect(retry.header, 'idem-fixed');
      expect(retry.store.records, hasLength(1));
    });

    test('forbidden endpoint does not emit a request key', () {
      final resolution = resolveIdempotencyKeyForEndpoint(
        EndpointCatalog.byId('recordings'),
        SubmissionKeyStore.empty,
        const IdempotencyRequestContext(explicitKey: 'should-not-send'),
      );

      expect(resolution.ok, isTrue);
      expect(resolution.header, isNull);
    });

    test(
      'workspace note policies and retired endpoint absence are explicit',
      () {
        for (final id in <String>[
          'createWorkspaceNote',
          'updateWorkspaceNote',
          'putWorkspaceNotePart',
        ]) {
          expect(
            EndpointCatalog.byId(id).idempotency,
            EndpointIdempotencyPolicy.required,
            reason: id,
          );
        }
        for (final id in <String>[
          'workspaceNotes',
          'workspaceNoteDetail',
          'workspaceNotePart',
        ]) {
          expect(
            EndpointCatalog.byId(id).idempotency,
            EndpointIdempotencyPolicy.forbidden,
            reason: id,
          );
        }
        for (final id in <String>[
          'updateMemoryNote',
          'createMemoryNoteAppend',
          'updateMyProfile',
          'createMyVoiceprint',
          'deleteMyVoiceprint',
          'memoryNoteAppends',
          'myVoiceprint',
          'myVoiceprintTask',
        ]) {
          expect(
            () => EndpointCatalog.byId(id),
            throwsArgumentError,
            reason: id,
          );
        }
      },
    );
  });
}

String _fixedKey() => 'idem-fixed';
