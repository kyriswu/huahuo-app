import 'dart:async';

import 'package:huahuoai_app/app/di/native_port_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_append_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_append_page.dart';

void main() {
  testWidgets('screen append rejects foreign sessions and guards stop', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('huahuoai/screen_capture');
    const events = 'huahuoai/screen_capture/events';
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? owned;
    final stopped = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCapability') {
        return <String, Object?>{
          'supported': true,
          'canCaptureSystemAudio': true,
          'requiresSystemPicker': true,
        };
      }
      if (call.method == 'startCapture') {
        owned = (call.arguments as Map)['sessionId'] as String;
      } else if (call.method == 'stopCapture') {
        stopped.add((call.arguments as Map)['expectedSessionId'] as String);
      }
      return <String, Object?>{
        'state': 'starting',
        'sessionId': owned,
        'elapsedSeconds': 0,
      };
    });
    messenger.setMockMessageHandler(
      events,
      (_) async => codec.encodeSuccessEnvelope(null),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMessageHandler(events, null);
    });
    final target = V3FeedItem(
      id: 'capture-target',
      title: '采集归属',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 9, 5),
      rawBody: '正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: const MaterialApp(
          home: V3NoteAppendPage(
            targetNoteId: 'capture-target',
            source: NoteAppendSource.internalRecording,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> foreignEvent() async {
      await messenger.handlePlatformMessage(
        events,
        codec.encodeSuccessEnvelope(<String, Object?>{
          'state': 'failed',
          'sessionId': 'main-internal-session',
          'elapsedSeconds': 0,
          'errorCode': 'SCREEN_CAPTURE_FOREIGN_FAILURE',
        }),
        (_) {},
      );
      await tester.pump();
    }

    await foreignEvent();
    expect(find.textContaining('SCREEN_CAPTURE_FOREIGN_FAILURE'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('note-append-primary-action')));
    await tester.pumpAndSettle();
    expect(owned, startsWith('append-'));
    expect(find.text('系统正在跨应用录屏'), findsOneWidget);
    await foreignEvent();
    expect(find.text('系统正在跨应用录屏'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-append-primary-action')));
    await tester.pumpAndSettle();
    expect(stopped, [owned]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(stopped.every((session) => session == owned), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('link append validates URL and clearly marks session demo', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final target = V3FeedItem(
      id: 'target-note',
      title: '客户研究',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 15),
      rawBody: '保留的原始正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(
        uploadDelay: Duration.zero,
        analysisDelay: Duration.zero,
      ),
    );
    final router = GoRouter(
      initialLocation: '/append',
      routes: [
        GoRoute(
          path: '/append',
          builder: (context, state) => const V3NoteAppendPage(
            targetNoteId: 'target-note',
            source: NoteAppendSource.link,
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('detail:${state.pathParameters['itemId']}'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('上传、分析及摘要更新仅在本次会话内保留'), findsOneWidget);
    expect(find.textContaining('不写入正式记忆库'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('note-append-link-input')),
      'not-a-url',
    );
    await tester.tap(find.byKey(const ValueKey('note-append-primary-action')));
    await tester.pump();
    expect(find.text('请输入有效的 http 或 https 链接。'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('note-append-link-input')),
      'https://example.com/article#fragment',
    );
    await tester.tap(find.byKey(const ValueKey('note-append-primary-action')));
    await tester.pumpAndSettle();

    expect(find.text('detail:target-note'), findsOneWidget);
    expect(append.itemsFor(target.id), hasLength(1));
    expect(append.itemsFor(target.id).single.isDemo, isTrue);
    expect(library.noteForId(target.id)?.rawBody, '保留的原始正文');
    expect(library.notes, hasLength(1));
  });

  testWidgets('read-only note disables append action', (tester) async {
    final target = V3FeedItem(
      id: 'readonly',
      title: '订阅资料',
      source: V3MaterialSource.subscription,
      ownership: V3NoteOwnership.subscribed,
      createdAt: DateTime(2026, 7, 15),
      rawBody: '只读正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: const MaterialApp(
          home: V3NoteAppendPage(
            targetNoteId: 'readonly',
            source: NoteAppendSource.link,
          ),
        ),
      ),
    );
    await tester.pump();

    final button = tester.widget<FilledButton>(find.byType(FilledButton).last);
    expect(button.onPressed, isNull);
    expect(find.text('目标笔记不存在、已删除或当前不可编辑。'), findsOneWidget);
    expect(append.itemsFor(target.id), isEmpty);
  });

  testWidgets('document chooser is not presented as append processing', (
    tester,
  ) async {
    final target = V3FeedItem(
      id: 'picker-target',
      title: '选择器状态',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 8, 31),
      rawBody: '正文',
    );
    final picker = _DeferredDocumentPicker();
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nativeFilePortProvider.overrideWithValue(picker),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: const MaterialApp(
          home: V3NoteAppendPage(
            targetNoteId: 'picker-target',
            source: NoteAppendSource.document,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('note-append-source-picker')));
    await tester.pump();

    final button = tester.widget<FilledButton>(find.byType(FilledButton).last);
    expect(button.onPressed, isNull);
    expect(find.text('正在进行分析'), findsNothing);
    expect(picker.calls, 1);

    picker.complete(NativeFileResult<List<PickedDocumentFile>>.cancelled());
    await tester.pump();

    final restoredButton = tester.widget<FilledButton>(
      find.byType(FilledButton).last,
    );
    expect(restoredButton.onPressed, isNotNull);
    expect(append.itemsFor(target.id), isEmpty);
  });

  testWidgets('recording-card picker uses its operation receipt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('note_append_recording_card_progress');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pendingDownload = Completer<Object?>();
    var downloadCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'scanFiles' => <String, Object?>{
          'files': <Object?>[
            <String, Object?>{
              'deviceFileId': 'append-card-file',
              'localFileKey': 'append-card-file-key',
              'deviceFilename': '20260905093000.m4a',
              'sizeBytes': 4096,
              'sizeConfidence': 'trusted',
              'format': 'm4a',
              'syncState': 'deviceOnly',
            },
          ],
        },
        'downloadFileToLocalCache' => () {
          downloadCalls += 1;
          return pendingDownload.future;
        }(),
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const _RecordingCardReadyFileStorage(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _recordingCardBindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      if (!pendingDownload.isCompleted) {
        pendingDownload.completeError(
          PlatformException(code: 'RECORDING_CARD_TEST_TRANSFER_CANCELLED'),
        );
      }
      await port.dispose();
      await events.close();
    });
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'append-card',
          'recordingFormat': 'm4a',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    final target = V3FeedItem(
      id: 'recording-card-target',
      title: '录音卡追加目标',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 9, 5),
      rawBody: '正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: const MaterialApp(
          home: V3NoteAppendPage(
            targetNoteId: 'recording-card-target',
            source: NoteAppendSource.recordingCard,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('note-append-source-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20260905093000.m4a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(downloadCalls, 1);
    final progressCard = find.byKey(
      const ValueKey('note-append-recording-card-download-progress'),
    );
    expect(progressCard, findsOneWidget);
    expect(find.text('正在建立传输连接'), findsOneWidget);

    events.add(<String, Object?>{
      'type': 'transfer_progress',
      'progress': <String, Object?>{
        'localFileKey': 'append-card-file-key',
        'receivedBytes': 1024,
        'totalBytes': 4096,
        'correlationId': 'append-transfer',
        'bytesPerSecond': 2048,
      },
    });
    await tester.pump();

    expect(find.text('1.0 KB / 4.0 KB · 2.0 KB/s · 预计剩余 2 秒'), findsOneWidget);
    final indicator = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: progressCard,
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(indicator.value, .25);

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'append-card-replacement',
          'recordingFormat': 'm4a',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    pendingDownload.complete(<String, Object?>{
      'localFileKey': 'append-card-file-key',
      'localFileId': 'append-card-local',
      'appPrivateUri': 'app-private://recording-card/append-card-local.m4a',
      'displayName': '20260905093000.m4a',
      'durationSeconds': 60,
      'sizeBytes': 4096,
      'contentHash':
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      'format': 'm4a',
      'mimeType': 'audio/mp4',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(progressCard, findsNothing);
    expect(controller.state.lastDownloadedFile, isNull);
    expect(find.text('待追加资料'), findsOneWidget);
    expect(find.text('20260905093000.m4a'), findsWidgets);
    expect(find.textContaining('4.0 KB · 录音卡文件'), findsOneWidget);
  });

  testWidgets(
    'compact media and keyboard search sheets keep choices reachable',
    (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final target = V3FeedItem(
        id: 'compact-target',
        title: '紧凑屏幕目标笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 9, 3),
        rawBody: '正文',
      );
      final related = V3FeedItem(
        id: 'compact-related',
        title: '键盘打开时仍可选择的关联笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 9, 2),
        rawBody: '关联正文',
      );
      final library = KnowledgeLibraryController(
        initialNotes: [target, related],
      );
      final append = NoteAppendController(
        knowledgeLibrary: library,
        port: const MockNoteAppendPort(),
      );
      var source = NoteAppendSource.media;
      late StateSetter setHostState;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            noteAppendControllerProvider.overrideWith((ref) => append),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return V3NoteAppendPage(
                  key: ValueKey(source),
                  targetNoteId: target.id,
                  source: source,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('note-append-source-picker')));
      await tester.pumpAndSettle();
      final firstMediaChoice = find.text('相册图片');
      final lastMediaChoice = find.text('拍摄视频');
      expect(firstMediaChoice.hitTestable(), findsOneWidget);
      expect(lastMediaChoice, findsOneWidget);
      await tester.ensureVisible(lastMediaChoice);
      await tester.pumpAndSettle();
      expect(lastMediaChoice.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(568, 320);
      setHostState(() => source = NoteAppendSource.relatedNote);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-append-source-picker')));
      await tester.pumpAndSettle();

      final search = find.byKey(
        const ValueKey('note-append-search-picker-input'),
      );
      await tester.tap(search);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      await tester.pumpAndSettle();

      final relatedChoice = find.text(related.title);
      expect(search.hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
      expect(relatedChoice.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(relatedChoice).dy, lessThanOrEqualTo(160));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful append returns to a pushed parent detail', (
    tester,
  ) async {
    final target = V3FeedItem(
      id: 'nested-target',
      title: '父详情',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 15),
      rawBody: '保留的原始正文',
    );
    final library = KnowledgeLibraryController(initialNotes: [target]);
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const MockNoteAppendPort(
        uploadDelay: Duration.zero,
        analysisDelay: Duration.zero,
      ),
    );
    final router = GoRouter(
      initialLocation: '/source',
      routes: [
        GoRoute(
          path: '/source',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/detail'),
                child: const Text('打开父详情'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/append'),
                child: const Text('打开追加'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/append',
          builder: (context, state) => const V3NoteAppendPage(
            targetNoteId: 'nested-target',
            source: NoteAppendSource.link,
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) =>
              Text('fallback:${state.pathParameters['itemId']}'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('打开父详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开追加'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('note-append-link-input')),
      'https://example.com/nested',
    );
    await tester.tap(find.byKey(const ValueKey('note-append-primary-action')));
    await tester.pumpAndSettle();

    expect(find.text('打开追加'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开父详情'), findsOneWidget);
  });
}

final class _DeferredDocumentPicker
    implements NativeFilePort, NativeDocumentFilePort {
  final Completer<NativeFileResult<List<PickedDocumentFile>>> _result =
      Completer<NativeFileResult<List<PickedDocumentFile>>>();
  int calls = 0;

  void complete(NativeFileResult<List<PickedDocumentFile>> result) {
    _result.complete(result);
  }

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.cancelled();

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() {
    calls += 1;
    return _result.future;
  }
}

final class _RecordingCardReadyFileStorage extends UnavailableFileStoragePort {
  const _RecordingCardReadyFileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult<PrivateAudioFileStat>.success(
    const PrivateAudioFileStat(exists: true, sizeBytes: 4096),
  );

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult<String>.success('e' * 64);
}

Future<String> _recordingCardBindingToken() async =>
    '0123456789abcdef0123456789abcdef';

final class _GrantedPermissionsPort implements PlatformPermissionsPort {
  const _GrantedPermissionsPort();

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async => PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
    PermissionSettingsOpenReceipt(
      kind: kind,
      opened: impactAcknowledged,
      impactText: buildPermissionImpactText(kind),
    ),
  );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        kinds
            .map(
              (kind) => PlatformPermissionSummary(
                kind: kind,
                status: PlatformPermissionStatus.granted,
                recoveryAction: PermissionRecoveryAction.none,
                impactText: buildPermissionImpactText(kind),
              ),
            )
            .toList(growable: false),
      );
}
