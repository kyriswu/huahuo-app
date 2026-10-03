import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/knowledge_export_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_export_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shares a prepared Markdown file without text or open fallback', () async {
    const channel = MethodChannel('huahuoai/knowledge_export');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final result = await const MethodChannelKnowledgeExportPort()
        .sharePreparedKnowledgeExport(
          opaqueExportRef:
              'app-private-export://knowledge/cache/export-share-one/knowledge.md',
          displayName: '我的笔记.md',
          mimeType: 'text/markdown',
        );

    expect(result.ok, isTrue);
    expect(result.value, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'sharePreparedKnowledgeExport');
    expect(calls.single.arguments, <String, String>{
      'opaqueExportRef':
          'app-private-export://knowledge/cache/export-share-one/knowledge.md',
      'displayName': '我的笔记.md',
      'mimeType': 'text/markdown',
    });
  });

  test('file share rejects invalid metadata and preserves cancellation', () async {
    final driver = _DocumentShareDriver();
    final port = MethodChannelKnowledgeExportPort(documentShareDriver: driver);
    final invalid = await port.sharePreparedKnowledgeExport(
      opaqueExportRef:
          'app-private-export://knowledge/cache/export-share-one/knowledge.md',
      displayName: '我的笔记.pdf',
      mimeType: 'text/markdown',
    );
    expect(invalid.ok, isFalse);
    expect(driver.calls, 0);

    final cancelled = await port.sharePreparedKnowledgeExport(
      opaqueExportRef:
          'app-private-export://knowledge/cache/export-share-one/knowledge.md',
      displayName: '我的笔记.md',
      mimeType: 'text/markdown',
    );
    expect(cancelled.ok, isTrue);
    expect(cancelled.value, isFalse);
    expect(driver.calls, 1);

    driver.failure = true;
    final failed = await port.sharePreparedKnowledgeExport(
      opaqueExportRef:
          'app-private-export://knowledge/cache/export-share-one/knowledge.md',
      displayName: '我的笔记.md',
      mimeType: 'text/markdown',
    );
    expect(failed.ok, isFalse);
    expect(failed.error?.code, 'NATIVE_KNOWLEDGE_EXPORT_UNAVAILABLE');
    expect(driver.calls, 2);
  });

  test(
    'dispatches validated Markdown, PDF, and ZIP prepared references',
    () async {
      final driver = _DocumentDriver();
      final port = MethodChannelKnowledgeExportPort(
        documentExportDriver: driver,
      );

      final markdown = await port.openPreparedKnowledgeExport(
        opaqueExportRef:
            'app-private-export://knowledge/cache/export-one/knowledge.md',
        displayName: '中文知识.md',
        mimeType: 'text/markdown',
      );
      final pdf = await port.openPreparedKnowledgeExport(
        opaqueExportRef:
            'app-private-export://knowledge/cache/export-two/knowledge.pdf',
        displayName: '中文知识.pdf',
        mimeType: 'application/pdf',
      );
      final archive = await port.openPreparedKnowledgeExport(
        opaqueExportRef:
            'app-private-export://knowledge/cache/export-three/digital-twin.zip',
        displayName: 'digital-twin-v1.zip',
        mimeType: 'application/zip',
      );

      expect(markdown.ok, isTrue);
      expect(pdf.ok, isTrue);
      expect(archive.ok, isTrue);
      expect(driver.calls, hasLength(3));
    },
  );

  test('rejects audio, traversal, absolute and mismatched metadata', () async {
    final driver = _DocumentDriver();
    final port = MethodChannelKnowledgeExportPort(documentExportDriver: driver);
    final requests = <({String ref, String name, String mime})>[
      (
        ref: 'app-private-export://recordings/cache/export-one/audio.m4a',
        name: 'audio.m4a',
        mime: 'audio/mp4',
      ),
      (
        ref: 'app-private-export://knowledge/cache/export-one/../secret.pdf',
        name: 'secret.pdf',
        mime: 'application/pdf',
      ),
      (
        ref: 'file:///private/knowledge.pdf',
        name: 'knowledge.pdf',
        mime: 'application/pdf',
      ),
      (
        ref: 'app-private-export://knowledge/cache/export-one/knowledge.pdf',
        name: 'knowledge.md',
        mime: 'text/markdown',
      ),
    ];

    for (final request in requests) {
      final result = await port.openPreparedKnowledgeExport(
        opaqueExportRef: request.ref,
        displayName: request.name,
        mimeType: request.mime,
      );
      expect(result.ok, isFalse);
      expect(result.error?.code, 'NATIVE_KNOWLEDGE_EXPORT_INVALID');
    }
    expect(driver.calls, isEmpty);
  });

  test('shares redacted text/public URL and preserves cancellation', () async {
    final driver = _ShareDriver(completed: false);
    final port = MethodChannelKnowledgeExportPort(shareDriver: driver);
    final payload = KnowledgeSharePayload.fromDocument(
      KnowledgeExportDocument(
        title: '分享知识',
        sourceLabel: '链接笔记',
        updatedAt: DateTime.utc(2026, 7, 19),
        summaryBody: '摘要 file:///Users/run/private.txt',
        publicUrl: 'https://example.com/public',
      ),
    );

    final result = await port.shareKnowledge(payload);

    expect(result.ok, isTrue);
    expect(result.value, isFalse);
    expect(driver.text, contains('https://example.com/public'));
    expect(driver.text, contains('[已隐藏私有路径]'));
    expect(driver.text, isNot(contains('/Users/run')));
  });

  test('maps platform failures without including private details', () async {
    final port = MethodChannelKnowledgeExportPort(
      documentExportDriver: _FailingDocumentDriver(),
    );

    final result = await port.openPreparedKnowledgeExport(
      opaqueExportRef:
          'app-private-export://knowledge/cache/export-one/knowledge.pdf',
      displayName: '知识.pdf',
      mimeType: 'application/pdf',
    );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'NATIVE_KNOWLEDGE_EXPORT_UNAVAILABLE');
    expect(result.error?.message, isNot(contains('/private')));
  });
}

final class _DocumentShareDriver implements NativePreparedDocumentShareDriver {
  int calls = 0;
  bool failure = false;

  @override
  Future<bool> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    calls += 1;
    if (failure) {
      throw PlatformException(code: 'NATIVE_KNOWLEDGE_EXPORT_UNAVAILABLE');
    }
    return false;
  }
}

final class _DocumentDriver implements NativePreparedDocumentExportDriver {
  final List<String> calls = <String>[];

  @override
  Future<bool> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    calls.add('$opaqueExportRef|$displayName|$mimeType');
    return true;
  }
}

final class _FailingDocumentDriver
    implements NativePreparedDocumentExportDriver {
  @override
  Future<bool> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) {
    throw PlatformException(
      code: 'NATIVE_KNOWLEDGE_EXPORT_UNAVAILABLE',
      message: 'Prepared knowledge export is unavailable',
    );
  }
}

final class _ShareDriver implements KnowledgeShareDriver {
  _ShareDriver({required this.completed});

  final bool completed;
  String? text;

  @override
  Future<bool> shareKnowledgeText(String text) async {
    this.text = text;
    return completed;
  }
}
