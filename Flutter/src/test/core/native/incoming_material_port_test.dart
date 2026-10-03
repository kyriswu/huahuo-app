import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/document_import_format.dart';
import 'package:huahuoai_app/core/native/incoming_material_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/incoming-material');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'projects audio and all Note formats with canonical document MIME',
    () async {
      const documentHashDigits = 'bcdef012';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'consumeIncomingMaterials');
            return <Object?>[
              <String, Object?>{
                'opaqueRef': 'incoming-material://audio-1',
                'displayName': 'voice.wav',
                'mimeType': 'audio/wav',
                'sizeBytes': 1200,
                'sourcePath': '/cache/huahuoai-incoming-materials/audio-1.wav',
                'contentHash': 'a' * 64,
                'origin': 'send',
              },
              for (
                var index = 0;
                index < DocumentImportFormat.values.length;
                index++
              )
                <String, Object?>{
                  'opaqueRef': 'incoming-material://doc-$index',
                  'displayName':
                      'notes.${DocumentImportFormat.values[index].extension}',
                  // The native handoff is allowed to be generic or wrong; the
                  // verified suffix supplies the import MIME contract.
                  'mimeType': index.isEven
                      ? 'application/octet-stream'
                      : 'application/x-provider-mismatch',
                  'sizeBytes': 320 + index,
                  'sourcePath':
                      '/cache/huahuoai-incoming-materials/doc-$index.${DocumentImportFormat.values[index].extension}',
                  'contentHash': documentHashDigits[index] * 64,
                  'origin': 'open',
                },
            ];
          });
      final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

      final result = await port.consumePendingMaterials();

      expect(result.ok, isTrue);
      expect(result.value, hasLength(1 + DocumentImportFormat.values.length));
      expect(result.value!.first.kind, IncomingMaterialKind.audio);
      final documents = result.value!
          .where((draft) => draft.kind == IncomingMaterialKind.document)
          .toList(growable: false);
      expect(documents, hasLength(DocumentImportFormat.values.length));
      for (var index = 0; index < DocumentImportFormat.values.length; index++) {
        expect(
          documents[index].mimeType,
          DocumentImportFormat.values[index].mimeType,
        );
      }
      expect(documents[1].toPickedDocument().isPlainText, isTrue);
    },
  );

  test('empty native queue is a successful no-op', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <Object?>[]);
    final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

    final result = await port.consumePendingMaterials();

    expect(result.ok, isTrue);
    expect(result.value, isEmpty);
  });

  test('reads only sanitized external material preparation failures', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'consumeIncomingMaterialErrors');
          return <Object?>[
            'INCOMING_MATERIAL_FORMAT_UNSUPPORTED',
            'INCOMING_MATERIAL_TOO_LARGE',
          ];
        });
    final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

    final result = await port.consumePendingMaterialErrors();

    expect(result.ok, isTrue);
    expect(result.value, <String>[
      'INCOMING_MATERIAL_FORMAT_UNSUPPORTED',
      'INCOMING_MATERIAL_TOO_LARGE',
    ]);
  });

  test('rejects malformed external material preparation failures', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <Object?>['provider path must not be exposed'],
        );
    final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

    final result = await port.consumePendingMaterialErrors();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'INCOMING_MATERIAL_ERROR_PAYLOAD_INVALID');
  });

  test('rejects unsupported or MIME-conflicting payloads', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <Object?>[
            <String, Object?>{
              'opaqueRef': 'incoming-material://bad',
              'displayName': 'voice.wav',
              'mimeType': 'application/pdf',
              'sizeBytes': 1200,
              'sourcePath': '/cache/huahuoai-incoming-materials/bad.wav',
              'contentHash': 'c' * 64,
              'origin': 'sendMultiple',
            },
          ],
        );
    final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

    final result = await port.consumePendingMaterials();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'INCOMING_MATERIAL_PAYLOAD_INVALID');
  });

  test('peek remains non-destructive until explicit opaque-ref ack', () async {
    var peekCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'consumeIncomingMaterials') {
            peekCount += 1;
            return <Object?>[
              <String, Object?>{
                'opaqueRef': 'incoming-material://doc-recoverable',
                'displayName': 'recoverable.pdf',
                'mimeType': 'application/pdf',
                'sizeBytes': 512,
                'sourcePath': '/private/recoverable.pdf',
                'contentHash': 'd' * 64,
                'origin': 'open',
              },
            ];
          }
          expect(call.method, 'acknowledgeIncomingMaterials');
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['opaqueRefs'], <String>[
            'incoming-material://doc-recoverable',
          ]);
          expect(arguments['discardFiles'], isTrue);
          return true;
        });
    final port = MethodChannelIncomingMaterialPort(methodChannel: channel);

    expect((await port.consumePendingMaterials()).value, hasLength(1));
    expect((await port.consumePendingMaterials()).value, hasLength(1));
    expect(peekCount, 2);
    final ack = await port.acknowledgePendingMaterials(<String>[
      'incoming-material://doc-recoverable',
    ]);
    expect(ack.ok, isTrue);
  });

  test('rejects payload without a verified SHA-256', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <Object?>[
            <String, Object?>{
              'opaqueRef': 'incoming-material://no-hash',
              'displayName': 'notes.txt',
              'mimeType': 'text/plain',
              'sizeBytes': 10,
              'sourcePath': '/private/notes.txt',
              'origin': 'send',
            },
          ],
        );
    final result = await MethodChannelIncomingMaterialPort(
      methodChannel: channel,
    ).consumePendingMaterials();
    expect(result.ok, isFalse);
    expect(result.error?.code, 'INCOMING_MATERIAL_PAYLOAD_INVALID');
  });
}
