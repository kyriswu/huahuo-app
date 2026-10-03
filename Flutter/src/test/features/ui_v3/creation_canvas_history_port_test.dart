import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_history.dart';

void main() {
  test('history entries stay isolated and newest entries sort first', () async {
    final port = InMemoryCreationCanvasHistoryPort();
    final older = _entry('history-a', 'note-a', DateTime.utc(2026, 7, 20));
    final newer = _entry('history-b', 'note-b', DateTime.utc(2026, 7, 21));

    await port.upsert('user-a', older);
    await port.upsert('user-a', newer);
    await port.upsert(
      'user-b',
      _entry('history-c', 'note-c', DateTime.utc(2026, 7, 22)),
    );

    expect(port.list('user-a').map((entry) => entry.id), [
      'history-b',
      'history-a',
    ]);
    expect(port.list('user-b').single.id, 'history-c');
    expect(port.find('user-b', 'history-a'), isNull);
  });

  test('upsert keeps latest snapshot and delete is scoped', () async {
    final port = InMemoryCreationCanvasHistoryPort();
    final initial = _entry('history-a', 'note-a', DateTime.utc(2026, 7, 20));
    final stale = _entry('history-a', 'note-a', DateTime.utc(2026, 7, 19));
    final latest = _entry(
      'history-a',
      'note-a',
      DateTime.utc(2026, 7, 22),
      title: '最新版本',
    );

    await port.upsert('user-a', initial);
    await port.upsert('user-a', stale);
    await port.upsert('user-a', latest);
    await port.upsert('user-b', initial);

    expect(port.find('user-a', 'history-a')!.title, '最新版本');
    expect(port.delete('user-a', 'history-a'), isTrue);
    expect(port.find('user-a', 'history-a'), isNull);
    expect(port.find('user-b', 'history-a'), isNotNull);
    expect(port.delete('user-a', 'history-a'), isFalse);
  });

  test('list returns an immutable snapshot', () async {
    final port = InMemoryCreationCanvasHistoryPort();
    await port.upsert(
      'user-a',
      _entry('history-a', 'note-a', DateTime.utc(2026, 7, 20)),
    );

    expect(() => port.list('user-a').clear(), throwsUnsupportedError);
  });
}

CreationCanvasHistoryEntry _entry(
  String id,
  String noteId,
  DateTime updatedAt, {
  String title = '创作标题',
}) {
  return CreationCanvasHistoryEntry(
    id: id,
    noteId: noteId,
    title: title,
    markdown: '正文',
    documentJson: '[{"insert":"正文\\n"}]',
    documentFormatVersion: 1,
    revision: 1,
    createdAt: DateTime.utc(2026, 7, 18),
    updatedAt: updatedAt,
  );
}
