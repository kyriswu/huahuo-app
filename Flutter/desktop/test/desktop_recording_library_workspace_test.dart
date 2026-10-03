import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/recordings/widgets/desktop_recording_library_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  testWidgets('failure retries to empty and upload entry works', (
    tester,
  ) async {
    final repository = _Repository()
      ..listResults.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        const ProductResult.success(<ProductRecording>[]),
      ]);
    var uploads = 0;

    await _pump(tester, repository, onUpload: () => uploads++);
    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('recordings-retry')));
    await tester.pumpAndSettle();
    expect(find.text('暂无云端录音'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('recordings-empty-upload')),
    );
    expect(uploads, 1);
  });

  testWidgets('opens detail, switches content, edits and submits speakers', (
    tester,
  ) async {
    final repository = _Repository()
      ..listResults.add(ProductResult.success([_recording(labels: true)]))
      ..detailResults.addAll([
        ProductResult.success(_detail(labels: true)),
        ProductResult.success(_detail()),
      ])
      ..panelResults.add(ProductResult.success(_panel()))
      ..submitResults.add(const ProductResult.success(null));

    await _pump(tester, repository);
    await tester.tap(
      find.byKey(const ValueKey<String>('recording-item-recording-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('完整转写'), findsOneWidget);
    await tester.tap(find.text('纲要'));
    await tester.pump();
    expect(find.text('# 会议纲要'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('speaker-name-speaker-1')),
      '小花',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('speaker-self-speaker-1')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('speaker-submit')));
    await tester.pumpAndSettle();

    expect(repository.submittedNames.single, {'speaker-1': '小花'});
    expect(repository.submittedVersions.single, 3);
  });

  testWidgets('executes server-authorized retry then refreshes detail', (
    tester,
  ) async {
    final repository = _Repository()
      ..listResults.add(ProductResult.success([_recording()]))
      ..detailResults.addAll([
        ProductResult.success(_detail()),
        ProductResult.success(_detail()),
      ])
      ..retryResults.add(const ProductResult.success(null));

    await _pump(tester, repository);
    await tester.tap(
      find.byKey(const ValueKey<String>('recording-item-recording-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('recording-retry-workspace_write')),
    );
    await tester.pumpAndSettle();

    expect(repository.retriedStages, ['workspace_write']);
    expect(repository.detailCalls, 2);
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProductRecordingsRepository repository, {
  VoidCallback? onUpload,
}) async {
  tester.view.physicalSize = const Size(1040, 680);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopRecordingLibraryWorkspace(
          workspaceId: 'workspace-1',
          repository: repository,
          onUploadAudio: onUpload ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProductRecording _recording({bool labels = false}) => ProductRecording(
  id: 'recording-1',
  title: '周会录音',
  workspaceId: 'workspace-1',
  transcriptStatus: labels ? 'speaker_labeling' : 'completed',
  minutesStatus: 'completed',
  summaryStatus: 'completed',
  depositStatus: 'deposited',
);

ProductRecordingDetail _detail({bool labels = false}) => ProductRecordingDetail(
  recording: _recording(labels: labels),
  asrTask: const ProductAsrTask(
    id: 'asr-1',
    status: 'speaker_labeling',
    version: 3,
  ),
  transcript: '完整转写',
  minutesMarkdown: '# 会议纲要',
  summary: '会议摘要',
  noteId: 'note-1',
  retryActions: const [
    ProductRecordingRetryAction(stage: 'workspace_write', title: '重新沉淀'),
  ],
);

ProductSpeakerPanel _panel() => ProductSpeakerPanel(
  recordingId: 'recording-1',
  asrTask: const ProductAsrTask(
    id: 'asr-1',
    status: 'speaker_labeling',
    version: 3,
  ),
  speakers: [
    ProductSpeakerCandidate(
      id: 'speaker-1',
      displayName: '说话人 1',
      segmentCount: 1,
      samples: const ['你好'],
    ),
  ],
  segments: const [
    ProductSpeakerSegment(
      speakerId: 'speaker-1',
      startMs: 0,
      endMs: 1000,
      text: '你好',
    ),
  ],
  names: const {'speaker-1': '说话人 1'},
  selfSpeakerId: null,
  previewText: '@说话人 1 你好',
  canSubmit: true,
  reason: null,
);

final class _Repository implements ProductRecordingsRepository {
  final listResults = <ProductResult<List<ProductRecording>>>[];
  final detailResults = <ProductResult<ProductRecordingDetail>>[];
  final panelResults = <ProductResult<ProductSpeakerPanel>>[];
  final submitResults = <ProductResult<void>>[];
  final retryResults = <ProductResult<void>>[];
  final submittedNames = <Map<String, String>>[];
  final submittedVersions = <int>[];
  final retriedStages = <String>[];
  int detailCalls = 0;

  @override
  Future<ProductResult<ProductRecordingDetail>> detail(
    String recordingId,
  ) async {
    detailCalls++;
    return detailResults.removeAt(0);
  }

  @override
  Future<ProductResult<List<ProductRecording>>> list(
    String workspaceId,
  ) async => listResults.removeAt(0);

  @override
  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(
    String recordingId,
  ) async => panelResults.removeAt(0);

  @override
  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async {
    retriedStages.add(stage);
    return retryResults.removeAt(0);
  }

  @override
  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) async => const ProductResult.success(null);

  @override
  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) async {
    submittedNames.add(Map<String, String>.of(names));
    submittedVersions.add(baseAsrTaskVersion);
    return submitResults.removeAt(0);
  }
}
