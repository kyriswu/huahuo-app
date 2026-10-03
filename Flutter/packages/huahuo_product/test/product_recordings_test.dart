import 'dart:async';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('loads empty then ready and selects full detail', () async {
    final repository = _Repository()
      ..lists.addAll([
        Future.value(const ProductResult.success(<ProductRecording>[])),
        Future.value(ProductResult.success([_recording()])),
      ])
      ..details.add(Future.value(ProductResult.success(_detail())));
    final controller = ProductRecordingsController(repository);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    expect(controller.state.status, ProductRecordingsStatus.empty);
    await controller.reload();
    await controller.select('recording-1');

    expect(controller.state.status, ProductRecordingsStatus.ready);
    expect(controller.state.detail?.transcript, '完整转写');
    expect(controller.state.detailStatus, ProductRecordingDetailStatus.ready);
  });

  test(
    'offline failure retries and unexpected exception is contained',
    () async {
      final repository = _Repository()
        ..lists.addAll([
          Future.value(
            const ProductResult.failure(
              code: 'OFFLINE',
              message: '网络不可用',
              retryable: true,
            ),
          ),
          Future.error(StateError('transport')),
        ]);
      final controller = ProductRecordingsController(repository);
      addTearDown(controller.dispose);

      await controller.bindWorkspace('workspace-1');
      expect(controller.state.retryable, isTrue);
      await controller.reload();
      expect(controller.state.errorCode, 'PRODUCT_RECORDINGS_UNEXPECTED');
    },
  );

  test(
    'newer load and Workspace replacement suppress stale responses',
    () async {
      final first = Completer<ProductResult<List<ProductRecording>>>();
      final second = Completer<ProductResult<List<ProductRecording>>>();
      final third = Completer<ProductResult<List<ProductRecording>>>();
      final repository = _Repository()
        ..lists.addAll([first.future, second.future, third.future]);
      final controller = ProductRecordingsController(repository);
      addTearDown(controller.dispose);

      final initial = controller.bindWorkspace('workspace-1');
      final newer = controller.reload();
      second.complete(ProductResult.success([_recording(title: 'new')]));
      await newer;
      first.complete(ProductResult.success([_recording(title: 'old')]));
      await initial;
      expect(controller.state.items.single.title, 'new');

      final replacement = controller.bindWorkspace('workspace-2');
      controller.reset();
      third.complete(ProductResult.success([_recording(title: 'stale')]));
      await replacement;
      expect(controller.state.status, ProductRecordingsStatus.idle);
    },
  );

  test('edits, saves, submits speakers and retries with stable keys', () async {
    final repository = _Repository()
      ..lists.add(Future.value(ProductResult.success([_recording()])))
      ..details.addAll([
        Future.value(ProductResult.success(_detail(requireLabels: true))),
        Future.value(ProductResult.success(_detail())),
        Future.value(ProductResult.success(_detail())),
      ])
      ..panels.add(Future.value(ProductResult.success(_panel())))
      ..draftResults.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        const ProductResult.success(null),
      ])
      ..submitResults.add(const ProductResult.success(null))
      ..retryResults.add(const ProductResult.success(null));
    var counter = 0;
    final controller = ProductRecordingsController(
      repository,
      keyFactory: (action) => 'key-${++counter}',
    );
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1');
    await controller.select('recording-1');

    controller.updateSpeakerName('speaker-1', '小花');
    controller.selectSelfSpeaker('speaker-1');
    expect(await controller.saveSpeakerDraft(), isFalse);
    expect(await controller.saveSpeakerDraft(), isTrue);
    expect(await controller.submitSpeakerLabels(), isTrue);
    expect(await controller.retryStage('workspace_write'), isTrue);

    expect(repository.keys.take(2).toList(), ['key-1', 'key-1']);
    expect(repository.submitVersions.single, 3);
    expect(repository.keys.last, 'key-3');
  });
}

ProductRecording _recording({String title = '周会', bool labels = false}) =>
    ProductRecording(
      id: 'recording-1',
      title: title,
      workspaceId: 'workspace-1',
      transcriptStatus: labels ? 'speaker_labeling' : 'completed',
      minutesStatus: 'completed',
      summaryStatus: 'completed',
      depositStatus: 'deposited',
      recordedAt: DateTime.utc(2026, 9, 3),
    );

ProductRecordingDetail _detail({bool requireLabels = false}) =>
    ProductRecordingDetail(
      recording: _recording(labels: requireLabels),
      asrTask: const ProductAsrTask(
        id: 'asr-1',
        status: 'speaker_labeling',
        version: 3,
      ),
      transcript: '完整转写',
      minutesMarkdown: '# 纲要',
      summary: '摘要',
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
  final lists = <Future<ProductResult<List<ProductRecording>>>>[];
  final details = <Future<ProductResult<ProductRecordingDetail>>>[];
  final panels = <Future<ProductResult<ProductSpeakerPanel>>>[];
  final draftResults = <ProductResult<void>>[];
  final submitResults = <ProductResult<void>>[];
  final retryResults = <ProductResult<void>>[];
  final keys = <String>[];
  final submitVersions = <int>[];

  @override
  Future<ProductResult<ProductRecordingDetail>> detail(String recordingId) =>
      details.removeAt(0);

  @override
  Future<ProductResult<List<ProductRecording>>> list(String workspaceId) =>
      lists.removeAt(0);

  @override
  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(String recordingId) =>
      panels.removeAt(0);

  @override
  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    return retryResults.removeAt(0);
  }

  @override
  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    return draftResults.removeAt(0);
  }

  @override
  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    submitVersions.add(baseAsrTaskVersion);
    return submitResults.removeAt(0);
  }
}
