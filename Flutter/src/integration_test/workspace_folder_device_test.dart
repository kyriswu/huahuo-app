import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const _enabled = bool.fromEnvironment(
  'HUAHUO_WORKSPACE_FOLDER_E2E',
  defaultValue: false,
);
const _phone = String.fromEnvironment('HUAHUO_WORKSPACE_FOLDER_E2E_PHONE');
const _code = String.fromEnvironment('HUAHUO_WORKSPACE_FOLDER_E2E_CODE');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'device creates a Workspace folder and moves an HNote through My Assets',
    (tester) async {
      final root = await _launchAuthenticatedApp(tester);
      final marker = DateTime.now().microsecondsSinceEpoch;
      final folderName = '设备目录回归$marker';
      String? folderId;
      KnowledgeLibraryController? cleanupLibrary;

      try {
        root.read(appRouterProvider).go('/v3/profile/assets?page=deposited');
        await _pumpUntil(
          tester,
          () => find.byType(V3MyAssetsPage).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 20),
          reason: 'My Assets did not open.',
        );
        final library = ProviderScope.containerOf(
          tester.element(find.byType(V3MyAssetsPage).last),
        ).read(knowledgeLibraryControllerProvider);
        cleanupLibrary = library;
        final temporary = library.createManualNote(
          title: '设备目录回归笔记$marker',
          rawBody: '此笔记仅用于验证工作空间目录和 HNote 批量移动。',
        );
        final synced = await _waitForRemoteNote(tester, library, temporary.id);
        debugPrint(
          '[WorkspaceFolderDeviceE2E] note=synchronized id=${synced.remoteNoteId}',
        );

        final createFolder = find.byKey(
          const ValueKey<String>('asset-create-deposit-folder'),
        );
        await tester.ensureVisible(createFolder);
        await tester.tap(createFolder);
        await tester.pump(const Duration(milliseconds: 250));
        final nameField = find.byKey(
          const ValueKey<String>('asset-deposit-folder-name'),
        );
        expect(nameField, findsOneWidget);
        await tester.enterText(nameField, folderName);
        await tester.tap(find.text('创建').last);

        await _pumpUntil(
          tester,
          () =>
              library.depositFolders.any((folder) => folder.name == folderName),
          timeout: const Duration(seconds: 30),
          reason:
              'Workspace Folder create did not reach the remote projection.',
        );
        final folder = library.depositFolders.singleWhere(
          (candidate) => candidate.name == folderName,
        );
        folderId = folder.id;
        debugPrint('[WorkspaceFolderDeviceE2E] folder=created id=$folderId');

        final returnToRoot = find.byKey(
          const ValueKey<String>('asset-deposit-folder-back'),
        );
        await _pumpUntil(
          tester,
          () => returnToRoot.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 10),
          reason: 'Newly created Workspace Folder did not open.',
        );
        await tester.tap(returnToRoot);
        await tester.pump();

        final noteActions = find.byKey(
          ValueKey<String>('asset-note-actions-${temporary.id}'),
        );
        await tester.pump();
        await _pumpUntil(
          tester,
          () => noteActions.evaluate().isNotEmpty,
          timeout: const Duration(seconds: 20),
          reason: 'The synchronized HNote did not render in My Assets.',
        );
        expect(noteActions, findsOneWidget);
        await tester.ensureVisible(noteActions);
        await tester.tap(noteActions);
        await tester.pump(const Duration(milliseconds: 250));
        final moveAction = find.text('移动到文件夹');
        expect(moveAction, findsOneWidget);
        await tester.tap(moveAction);
        await tester.pump(const Duration(milliseconds: 250));
        final destination = find.text(folderName);
        expect(destination, findsOneWidget);
        await tester.tap(destination);
        await tester.tap(
          find.byKey(const ValueKey<String>('deposit-picker-confirm')),
        );

        await _pumpUntil(
          tester,
          () => library.noteForId(temporary.id)?.folderId == folderId,
          timeout: const Duration(seconds: 45),
          reason: 'HNote batch move did not update the Workspace projection.',
        );
        expect(library.depositRecordFor(temporary.id)?.folderId, folderId);
        expect(tester.takeException(), isNull);
        await binding.takeScreenshot('workspace_folder_hnote_move');
        debugPrint(
          '[WorkspaceFolderDeviceE2E] hnote=batch-moved folder=$folderId',
        );
      } finally {
        final library = cleanupLibrary;
        if (folderId != null && library != null) {
          final deleted = await library.deleteWorkspaceDepositFolder(folderId);
          debugPrint(
            '[WorkspaceFolderDeviceE2E] cleanup=${deleted.status.name} folder=$folderId',
          );
        }
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<ProviderContainer> _launchAuthenticatedApp(WidgetTester tester) async {
  await app.main();
  await _pumpUntil(
    tester,
    () => find.byType(Scaffold).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
    reason: 'The application did not render a scaffold.',
  );
  final root = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  );
  if (root.read(sessionStoreProvider).state.authState !=
      SessionAuthState.authenticated) {
    expect(_phone, isNotEmpty, reason: 'A device-test phone is required.');
    expect(_code, isNotEmpty, reason: 'A device-test code is required.');
    final auth = root.read(authControllerProvider);
    auth.setPhone(_phone);
    await auth.sendSmsCode();
    expect(
      auth.state.smsRequestId,
      isNotNull,
      reason: auth.state.lastErrorCode,
    );
    auth.setCode(_code);
    auth.setAgreementAccepted(true);
    await auth.login();
  }
  await _pumpUntil(
    tester,
    () {
      final state = root.read(sessionStoreProvider).state;
      return state.authState == SessionAuthState.authenticated &&
          state.workspaceStatus == SessionWorkspaceStatus.ready;
    },
    timeout: const Duration(seconds: 45),
    reason: 'Authentication or Workspace provisioning did not become ready.',
  );
  return root;
}

Future<V3FeedItem> _waitForRemoteNote(
  WidgetTester tester,
  KnowledgeLibraryController library,
  String localId,
) async {
  V3FeedItem? note;
  await _pumpUntil(
    tester,
    () {
      note = library.noteForId(localId);
      return note?.syncState == NoteSyncState.synced &&
          note?.remoteNoteId?.trim().isNotEmpty == true &&
          note?.etag?.trim().isNotEmpty == true;
    },
    timeout: const Duration(seconds: 75),
    reason: 'The temporary HNote did not receive a remote ETag.',
  );
  return note!;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  }
  expect(condition(), isTrue, reason: reason);
}
