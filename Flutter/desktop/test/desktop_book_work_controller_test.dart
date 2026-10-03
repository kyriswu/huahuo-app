import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/book_work/application/desktop_book_work_controller.dart';

import 'support/desktop_port_fakes.dart';

void main() {
  test('long Work IDs receive distinct valid Book Section keys', () {
    final first = DesktopBookWorkController.sectionKeyForWorkId(
      'work-with-the-same-very-long-prefix-alpha',
    );
    final second = DesktopBookWorkController.sectionKeyForWorkId(
      'work-with-the-same-very-long-prefix-beta',
    );

    expect(first, isNot(second));
    expect(first.length, lessThanOrEqualTo(32));
    expect(second.length, lessThanOrEqualTo(32));
    expect(RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(first), isTrue);
    expect(RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(second), isTrue);
  });

  test('Book and Work reads require an account-scoped Workspace', () async {
    final port = FakeDesktopBookWorkPort();
    final controller = DesktopBookWorkController(port);

    expect(
      (await controller.loadBook()).code,
      'DESKTOP_BOOK_WORK_ACCOUNT_REQUIRED',
    );
    expect(
      (await controller.loadAllWorks()).code,
      'DESKTOP_BOOK_WORK_ACCOUNT_REQUIRED',
    );
    expect(port.operations, isEmpty);

    controller.bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
    expect((await controller.loadBook()).isSuccess, isTrue);
    expect((await controller.loadAllWorks()).data, hasLength(1));
    expect(port.operations, contains('book:workspace-1'));
  });

  test('Work paging stops and reports a repeated cursor', () async {
    final port = FakeDesktopBookWorkPort()..repeatWorkCursor = true;
    final controller = DesktopBookWorkController(port)
      ..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await controller.loadAllWorks();

    expect(result.isFailure, isTrue);
    expect(result.code, 'DESKTOP_WORK_CURSOR_REPEATED');
    expect(
      port.operations.where((operation) => operation.startsWith('works:')),
      hasLength(2),
    );
  });

  test('Work paging rejects conflicting duplicate Work identities', () async {
    final port = FakeDesktopBookWorkPort()..conflictingDuplicateWork = true;
    final controller = DesktopBookWorkController(port)
      ..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final result = await controller.loadAllWorks();

    expect(result.code, 'DESKTOP_WORK_DUPLICATE_ID_CONFLICT');
    expect(result.isFailure, isTrue);
  });

  test(
    'Book Section and Work Part reads use exact current revisions',
    () async {
      final port = FakeDesktopBookWorkPort();
      final controller = DesktopBookWorkController(port)
        ..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

      final bookPart = await controller.loadBookSectionPart(
        section: port.book.sections.first,
        part: 'raw',
      );
      final workPart = await controller.loadWorkPart(
        work: port.works.first,
        part: 'outline',
      );

      expect(bookPart.data?.partRevisionId, 'book-preface-raw-1');
      expect(port.lastBookPartRevisionId, 'book-preface-raw-1');
      expect(workPart.data?.partRevisionId, 'work-outline-1');
      expect(port.lastWorkPartRevisionId, 'work-outline-1');
    },
  );

  test(
    'Work completion retries with stable idempotency key and ETag',
    () async {
      final keys = <String>['complete-key-1', 'complete-key-2'];
      final port = FakeDesktopBookWorkPort()..completeFailureCount = 1;
      final controller = DesktopBookWorkController(
        port,
        idempotencyKeyFactory: () => keys.removeAt(0),
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
      final work = port.works.first;

      expect((await controller.completeWork(work)).isFailure, isTrue);
      expect((await controller.completeWork(work)).isSuccess, isTrue);
      expect((await controller.completeWork(work)).isSuccess, isTrue);

      expect(port.idempotencyKeys, <String>[
        'complete-key-1',
        'complete-key-1',
        'complete-key-2',
      ]);
      expect(port.etags, <String>[work.etag, work.etag, work.etag]);
    },
  );

  test(
    'Book promotion pins exact source revision and stable retry intent',
    () async {
      final port = FakeDesktopBookWorkPort()..promoteFailureCount = 1;
      final controller = DesktopBookWorkController(
        port,
        idempotencyKeyFactory: () => 'promote-key-1',
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');
      final work = port.works.first;

      final failed = await controller.promoteWorkToBookSection(
        work: work,
        part: 'raw',
        sectionKey: 'w_work_test',
        title: work.title,
      );
      final retried = await controller.promoteWorkToBookSection(
        work: work,
        part: 'raw',
        sectionKey: 'w_work_test',
        title: work.title,
      );

      expect(failed.isFailure, isTrue);
      expect(retried.isSuccess, isTrue);
      expect(port.idempotencyKeys, <String>['promote-key-1', 'promote-key-1']);
      expect(port.etags, <String>[work.etag, work.etag]);
      expect(port.lastPromotionRequest?.target, 'book_section');
      expect(port.lastPromotionRequest?.sourcePart, 'raw');
      expect(port.lastPromotionRequest?.sourcePartRevisionId, 'work-raw-1');
      expect(port.lastPromotionRequest?.bookSectionKey, 'w_work_test');
    },
  );

  test('Account changes clear retained mutation intent', () async {
    final keys = <String>['user-1-key', 'user-2-key'];
    final port = FakeDesktopBookWorkPort()..completeFailureCount = 2;
    final controller = DesktopBookWorkController(
      port,
      idempotencyKeyFactory: () => keys.removeAt(0),
    )..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    await controller.completeWork(port.works.first);
    controller.bindAccount(userId: 'user-2', workspaceId: 'workspace-2');
    await controller.completeWork(port.works.first);

    expect(port.idempotencyKeys, <String>['user-1-key', 'user-2-key']);
    expect(port.operations, contains('complete:workspace-2:work-test'));
  });

  test('stale reads are rejected when account changes during await', () async {
    final gate = Completer<void>();
    final port = FakeDesktopBookWorkPort()..loadBookGate = gate;
    final controller = DesktopBookWorkController(port)
      ..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

    final pending = controller.loadBook();
    await Future<void>.delayed(Duration.zero);
    controller.bindAccount(userId: 'user-2', workspaceId: 'workspace-2');
    gate.complete();
    final result = await pending;

    expect(result.code, 'DESKTOP_BOOK_WORK_ACCOUNT_CHANGED');
    expect(result.data, isNull);
  });

  test(
    'stale mutation cannot remove a new account pending mutation scope',
    () async {
      final gate = Completer<void>();
      final keys = <String>['old-account-key', 'new-account-key'];
      final port = FakeDesktopBookWorkPort()..completeGate = gate;
      final controller = DesktopBookWorkController(
        port,
        idempotencyKeyFactory: () => keys.removeAt(0),
      )..bindAccount(userId: 'user-1', workspaceId: 'workspace-1');

      final stale = controller.completeWork(port.works.first);
      await Future<void>.delayed(Duration.zero);
      controller.bindAccount(userId: 'user-2', workspaceId: 'workspace-2');
      final current = controller.completeWork(port.works.first);
      await Future<void>.delayed(Duration.zero);
      gate.complete();

      expect((await stale).code, 'DESKTOP_BOOK_WORK_ACCOUNT_CHANGED');
      expect((await current).isSuccess, isTrue);
      expect(port.idempotencyKeys, <String>[
        'old-account-key',
        'new-account-key',
      ]);
    },
  );
}
