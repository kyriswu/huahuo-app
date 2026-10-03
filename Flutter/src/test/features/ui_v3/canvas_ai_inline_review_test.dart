import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_ai_inline_review.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_document_codec.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_image_embed_data.dart';

void main() {
  test('review is a read-only projection with a clean immutable candidate', () {
    final base = Delta()..insert('before old after\n');
    final candidate = Delta()..insert('before new after\n');
    final baseSnapshot = base.toJson();
    final candidateSnapshot = candidate.toJson();
    final review = CanvasAiInlineReview(base: base, candidate: candidate);
    addTearDown(review.dispose);

    expect(review.editor.readOnly, isTrue);
    expect(review.editor.document.toPlainText(), 'before oldnew after\n');
    expect(base.toJson(), baseSnapshot);
    expect(candidate.toJson(), candidateSnapshot);
    expect(review.candidateDelta.toJson(), candidateSnapshot);
    expect(
      review.candidateDelta.toJson().toString(),
      isNot(contains('canvas-review')),
    );

    final operations = review.editor.document.toDelta().toList();
    expect(
      operations
          .where(
            (operation) =>
                CanvasAiInlineReview.changeFor(operation.attributes) ==
                CanvasReviewChange.deleted,
          )
          .map((operation) => operation.data)
          .join(),
      'old',
    );
    expect(
      operations
          .where(
            (operation) =>
                CanvasAiInlineReview.changeFor(operation.attributes) ==
                CanvasReviewChange.inserted,
          )
          .map((operation) => operation.data)
          .join(),
      'new',
    );
    expect(
      operations
          .where(
            (operation) =>
                CanvasAiInlineReview.changeFor(operation.attributes) == null,
          )
          .map((operation) => operation.data)
          .join(),
      'before  after\n',
    );
    expect(
      operations.any(
        (operation) =>
            CanvasAiInlineReview.changeFor(operation.attributes) == null,
      ),
      isTrue,
    );
    expect(review.insertedCharacterCount, 3);
    expect(review.deletedCharacterCount, 3);

    review.editor.replaceText(
      0,
      6,
      'changed',
      const TextSelection.collapsed(offset: 7),
    );
    expect(review.editor.document.toPlainText(), 'before oldnew after\n');
    expect(review.candidateDelta.toJson(), candidateSnapshot);
  });

  test(
    'projection selection maps to candidate and copies no deletion text',
    () {
      final review = CanvasAiInlineReview(
        base: Delta()..insert('before old after\n'),
        candidate: Delta()..insert('before new after\n'),
      );
      addTearDown(review.dispose);
      final projection = review.editor.document.toPlainText();
      final oldStart = projection.indexOf('old');
      final newEnd = projection.indexOf('new') + 'new'.length;
      final selection = TextSelection(
        baseOffset: newEnd,
        extentOffset: oldStart,
        affinity: TextAffinity.upstream,
        isDirectional: true,
      );

      expect(
        review.mapProjectionSelectionToCandidate(selection),
        const TextSelection(
          baseOffset: 10,
          extentOffset: 7,
          affinity: TextAffinity.upstream,
          isDirectional: true,
        ),
      );
      expect(review.candidateTextForProjectionSelection(selection), 'new');

      review.editor.updateSelection(selection, ChangeSource.local);
      expect(
        review.candidateSelection,
        const TextSelection(
          baseOffset: 10,
          extentOffset: 7,
          affinity: TextAffinity.upstream,
          isDirectional: true,
        ),
      );

      final deletedOnly = TextSelection(
        baseOffset: oldStart,
        extentOffset: oldStart + 'old'.length,
      );
      expect(
        review.mapProjectionSelectionToCandidate(deletedOnly),
        const TextSelection.collapsed(offset: 7),
      );
      expect(review.candidateTextForProjectionSelection(deletedOnly), isEmpty);
    },
  );

  test('initial candidate caret maps through middle-document deletions', () {
    const caret = TextSelection.collapsed(offset: 10);
    final review = CanvasAiInlineReview(
      base: Delta()..insert('before old after\n'),
      candidate: Delta()..insert('before new after\n'),
      initialCandidateSelection: caret,
    );
    addTearDown(review.dispose);

    expect(review.editor.selection.baseOffset, greaterThan(caret.baseOffset));
    expect(review.candidateSelection, caret);
    expect(
      review.mapCandidateSelectionToProjection(caret),
      review.editor.selection,
    );
  });

  test('deleted embeds keep deletion tokens in the review projection', () {
    final base = Delta()
      ..insert({
        'canvas-image': {'resourceId': 'review-image.png'},
      })
      ..insert('\n')
      ..insert({
        'canvas-divider': {'version': 1},
      })
      ..insert('\nsource\n');
    final review = CanvasAiInlineReview(
      base: base,
      candidate: Delta()..insert('candidate\n'),
    );
    addTearDown(review.dispose);

    final deletedEmbeds = review.editor.document
        .toDelta()
        .toList()
        .where(
          (operation) =>
              operation.data is Map &&
              CanvasAiInlineReview.changeFor(operation.attributes) ==
                  CanvasReviewChange.deleted,
        )
        .map((operation) => operation.data)
        .toList();
    expect(deletedEmbeds, hasLength(2));
    expect(deletedEmbeds.first.toString(), contains('canvas-image'));
    expect(deletedEmbeds.last.toString(), contains('canvas-divider'));
  });

  test('block formatting changes show complete deleted and inserted lines', () {
    final base = Delta()
      ..insert('A heading')
      ..insert('\n', {'header': 1})
      ..insert('after\n');
    final candidate = Delta()
      ..insert('A heading')
      ..insert('\n', {'header': 2})
      ..insert('after\n');
    final review = CanvasAiInlineReview(base: base, candidate: candidate);
    addTearDown(review.dispose);

    expect(
      review.editor.document.toPlainText(),
      'A heading\nA heading\nafter\n',
    );
    final operations = review.editor.document.toDelta().toList();
    expect(
      operations.where((operation) => operation.attributes?['header'] == 1),
      hasLength(1),
    );
    expect(
      operations.where((operation) => operation.attributes?['header'] == 2),
      hasLength(1),
    );
    expect(
      operations
          .where((operation) => operation.attributes?['header'] == 1)
          .every(
            (operation) =>
                CanvasAiInlineReview.changeFor(operation.attributes) ==
                CanvasReviewChange.deleted,
          ),
      isTrue,
    );
    expect(
      operations
          .where((operation) => operation.attributes?['header'] == 2)
          .every(
            (operation) =>
                CanvasAiInlineReview.changeFor(operation.attributes) ==
                CanvasReviewChange.inserted,
          ),
      isTrue,
    );
    expect(review.insertedCharacterCount, 'A heading\n'.length);
    expect(review.deletedCharacterCount, 'A heading\n'.length);
    expect(review.candidateDelta.toJson(), candidate.toJson());
  });

  test('emoji edits never split surrogate pairs across review runs', () {
    final review = CanvasAiInlineReview(
      base: Delta()..insert('原文😀\n'),
      candidate: Delta()..insert('新文😃\n'),
    );
    addTearDown(review.dispose);

    expect(Document.fromDelta(review.candidateDelta).toPlainText(), '新文😃\n');
    for (final operation in review.editor.document.toDelta().toList()) {
      final data = operation.data;
      if (data is String) {
        expect(
          data.runes.where((rune) => rune >= 0xD800 && rune <= 0xDFFF),
          isEmpty,
        );
      }
    }
  });

  test('review changes never split extended grapheme clusters across runs', () {
    const deletedClusters = <String>['👩‍💻', '👍🏽', 'e\u0301'];
    const insertedClusters = <String>['👩‍🔬', '👍🏻', 'e\u0300'];
    final review = CanvasAiInlineReview(
      base: Delta()..insert('${deletedClusters.join(' ')}\n'),
      candidate: Delta()..insert('${insertedClusters.join(' ')}\n'),
    );
    addTearDown(review.dispose);

    final changedRuns = review.editor.document
        .toDelta()
        .toList()
        .where(
          (operation) =>
              operation.data is String &&
              CanvasAiInlineReview.changeFor(operation.attributes) != null,
        )
        .map((operation) => operation.data! as String)
        .toList(growable: false);
    for (final cluster in [...deletedClusters, ...insertedClusters]) {
      expect(
        changedRuns.where((run) => run.contains(cluster)),
        hasLength(1),
        reason: 'The grapheme cluster $cluster must belong to one styled run',
      );
    }
  });

  test(
    'candidate copy renders image, divider, and unknown embeds readably',
    () {
      final image = CanvasImageEmbedData(
        resourceId: 'review-copy.png',
        alt: '审核配图',
        widthRatio: .5,
        aspectRatio: 4 / 3,
      );
      final candidate = Delta()
        ..insert(image.toDeltaInsert())
        ..insert('\n')
        ..insert(CanvasDocumentCodec.canvasDividerDeltaInsert)
        ..insert('\n')
        ..insert({
          'custom-card': {'id': 'unknown-embed'},
        })
        ..insert('\n');
      final review = CanvasAiInlineReview(
        base: candidate,
        candidate: candidate,
      );
      addTearDown(review.dispose);

      String copyCandidateRange(int start, int end) =>
          review.candidateTextForProjectionSelection(
            review.mapCandidateSelectionToProjection(
              TextSelection(baseOffset: start, extentOffset: end),
            ),
          );

      expect(copyCandidateRange(0, 1), '[图片：审核配图]');
      expect(copyCandidateRange(2, 3), '\n---\n');
      expect(copyCandidateRange(4, 5), '[嵌入内容]');
      expect(
        copyCandidateRange(0, 5),
        isNot(contains(Embed.kObjectReplacementCharacter)),
      );
    },
  );

  test(
    'review cleans inherited markers and restores original token values',
    () {
      const inherited =
          'huahuo:canvas-review:{"change":"inserted","original":"real-token"}';
      final source = Delta()
        ..insert('copied', {'token': inherited})
        ..insert('\n');
      final review = CanvasAiInlineReview(base: source, candidate: source);
      addTearDown(review.dispose);

      expect(
        review.candidateDelta.toJson(),
        (Delta()
              ..insert('copied', {'token': 'real-token'})
              ..insert('\n'))
            .toJson(),
      );
      final projectionOperation = review.editor.document
          .toDelta()
          .toList()
          .first;
      expect(projectionOperation.attributes?['token'], 'real-token');
      expect(
        CanvasAiInlineReview.changeFor(projectionOperation.attributes),
        isNull,
      );
      expect(review.insertedCharacterCount, 0);
      expect(review.deletedCharacterCount, 0);
    },
  );

  test('legacy retained review tokens are read as inserted evidence', () {
    const legacyToken =
        'huahuo:canvas-review:{"change":"retained","original":null}';

    expect(
      CanvasAiInlineReview.changeFor(const {'token': legacyToken}),
      CanvasReviewChange.inserted,
    );
  });

  test('review preserves rich embeds and long candidate content', () {
    final prefix = '前文😀' * 4000;
    final base = Delta()
      ..insert('$prefix\n', {'bold': true})
      ..insert({'divider': true})
      ..insert('\nold\nafter\n');
    final candidate = Delta()
      ..insert('$prefix\n', {'bold': true})
      ..insert({'divider': true})
      ..insert('\nnew\nafter\n');
    final review = CanvasAiInlineReview(base: base, candidate: candidate);
    addTearDown(review.dispose);

    expect(review.candidateDelta.toJson(), candidate.toJson());
    expect(review.editor.document.toPlainText(), startsWith(prefix));
    expect(review.editor.document.toPlainText(), endsWith('after\n'));
    expect(
      review.editor.document.toDelta().toJson().toString(),
      contains('divider'),
    );

    final projection = review.editor.document.toPlainText();
    final selection = TextSelection(
      baseOffset: projection.indexOf('old'),
      extentOffset: projection.indexOf('new') + 3,
    );
    expect(review.candidateTextForProjectionSelection(selection), 'new');
  });
}
