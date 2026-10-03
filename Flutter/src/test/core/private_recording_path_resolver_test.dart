import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/storage/private_recording_path_resolver.dart';

void main() {
  group('PrivateRecordingPathResolver', () {
    test('parses canonical RN references and rejects unsafe values', () {
      final resolver = PrivateRecordingPathResolver();

      expect(
        resolver.parse('app-private://meeting-1.m4a')?.kind,
        PrivateRecordingReferenceKind.localRecording,
      );
      expect(
        resolver.parse('app-private://Voice-ABC.m4a')?.fileId,
        'Voice-ABC.m4a',
      );
      expect(
        resolver.parse('app-private://recording-card/card-1.opus')?.kind,
        PrivateRecordingReferenceKind.recordingCard,
      );
      expect(
        resolver.parse('app-private://recordings/old-1/source.m4a')?.kind,
        PrivateRecordingReferenceKind.legacyFlutter,
      );
      expect(resolver.parse('app-private://recording-card/../secret'), isNull);
      expect(resolver.parse('app-private://meeting.part'), isNull);
      expect(resolver.parse('app-private://meeting.m4a?token=1'), isNull);
      expect(resolver.parse('file:///tmp/meeting.m4a'), isNull);
      final legacy = resolver.parse(
        'app-private://recordings/card-old/source.m4a',
      )!;
      expect(
        resolver.canonicalUriForLegacy(legacy, recordingCard: true),
        'app-private://recording-card/card-old-source.m4a',
      );
    });

    test(
      'maps iOS references to the RN Application Support directories',
      () async {
        final support = Directory('/support');
        final documents = Directory('/documents');
        final resolver = PrivateRecordingPathResolver(
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => support,
          documentsDirectory: () async => documents,
        );

        expect(
          (await resolver.resolveFile('app-private://meeting.m4a'))?.path,
          '/support/HuahuoAI/Recordings/meeting.m4a',
        );
        expect(
          (await resolver.resolveFile(
            'app-private://recording-card/card.opus',
          ))?.path,
          '/support/HuahuoAI/Recordings/RecordingCard/card.opus',
        );
        expect(
          (await resolver.resolveFile(
            'app-private://recordings/old/source.m4a',
          ))?.path,
          '/documents/recordings/library/old/source.m4a',
        );
      },
    );

    test(
      'maps Android references to RN filesDir recording directories',
      () async {
        final resolver = PrivateRecordingPathResolver(
          platform: PrivateRecordingPlatform.android,
          applicationSupportDirectory: () async => Directory('/files'),
          documentsDirectory: () async => Directory('/documents'),
        );

        expect(
          (await resolver.resolveFile('app-private://meeting.m4a'))?.path,
          '/files/recordings/imports/meeting.m4a',
        );
        expect(
          (await resolver.resolveFile(
            'app-private://recording-card/card.mp3',
          ))?.path,
          '/files/recordings/recording-card/card.mp3',
        );
        expect(
          (await resolver.resolveFile(
            'app-private://recordings/old/source.m4a',
          ))?.path,
          '/files/recordings/library/old/source.m4a',
        );
      },
    );

    test(
      'falls back to historical roots and discovers safe audio files',
      () async {
        final support = await Directory.systemTemp.createTemp(
          'recording-support',
        );
        final documents = await Directory.systemTemp.createTemp(
          'recording-documents',
        );
        addTearDown(() => support.delete(recursive: true));
        addTearDown(() => documents.delete(recursive: true));
        final historical = File(
          '${documents.path}/HuahuoAI/Recordings/old-meeting.m4a',
        );
        await historical.parent.create(recursive: true);
        await historical.writeAsBytes(<int>[1, 2, 3]);
        await File('${historical.path}.part').writeAsBytes(<int>[4]);
        final resolver = PrivateRecordingPathResolver(
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => support,
          documentsDirectory: () async => documents,
        );

        final resolved = await resolver.resolveFile(
          'app-private://old-meeting.m4a',
        );
        final discovered = await resolver.discoverExistingRecordings();

        expect(resolved?.path, historical.path);
        expect(
          discovered.map((item) => item.appPrivateUri),
          contains('app-private://old-meeting.m4a'),
        );
        expect(
          discovered.any((item) => item.fileName.endsWith('.part')),
          isFalse,
        );
      },
    );

    test(
      'isolates authenticated account folders and excludes global history',
      () async {
        final support = await Directory.systemTemp.createTemp(
          'recording-account-support',
        );
        final documents = await Directory.systemTemp.createTemp(
          'recording-account-documents',
        );
        addTearDown(() async {
          if (await support.exists()) await support.delete(recursive: true);
          if (await documents.exists()) await documents.delete(recursive: true);
        });
        final legacy = File('${support.path}/HuahuoAI/Recordings/shared.m4a');
        await legacy.parent.create(recursive: true);
        await legacy.writeAsBytes(<int>[1, 2, 3]);

        final accountA = PrivateRecordingPathResolver(
          accountScope: 'user-a',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => support,
          documentsDirectory: () async => documents,
        );
        final accountB = PrivateRecordingPathResolver(
          accountScope: 'user-b',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => support,
          documentsDirectory: () async => documents,
        );
        const uri = 'app-private://shared.m4a';
        final fileA = await accountA.resolveFile(uri);
        final fileB = await accountB.resolveFile(uri);

        expect(fileA, isNotNull);
        expect(fileB, isNotNull);
        expect(fileA!.path, contains('/HuahuoAI/Users/'));
        expect(fileA.path, isNot(fileB!.path));
        expect(await fileA.exists(), isFalse);
        expect(await fileB.exists(), isFalse);

        await fileA.parent.create(recursive: true);
        await fileA.writeAsBytes(<int>[9, 8, 7]);
        final discoveredA = await accountA.discoverExistingRecordings();
        final discoveredB = await accountB.discoverExistingRecordings();

        expect(discoveredA.map((item) => item.appPrivateUri), contains(uri));
        expect(discoveredB, isEmpty);
        expect(await legacy.exists(), isTrue);
      },
    );

    test('exposes only an irreversible native recorder directory scope', () {
      final resolver = PrivateRecordingPathResolver(accountScope: 'user-a');

      expect(
        resolver.nativeRecorderDirectoryScope,
        matches(RegExp(r'^u-[a-f0-9]{32}$')),
      );
      expect(
        resolver.temporaryTransferDirectoryScope,
        resolver.nativeRecorderDirectoryScope,
      );
      expect(resolver.nativeRecorderDirectoryScope, isNot(contains('user-a')));
      expect(
        PrivateRecordingPathResolver().nativeRecorderDirectoryScope,
        isNull,
      );
      expect(
        PrivateRecordingPathResolver().temporaryTransferDirectoryScope,
        isNull,
      );
    });
  });
}
