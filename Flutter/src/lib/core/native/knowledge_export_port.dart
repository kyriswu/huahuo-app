import 'package:flutter/services.dart';

import '../../features/ui_v3/domain/knowledge_export_models.dart';
import '../api/api_envelope.dart';
import 'native_file_port.dart';

abstract interface class KnowledgeSharePort {
  Future<NativeFileResult<bool>> shareKnowledge(KnowledgeSharePayload payload);
}

abstract interface class NativePreparedDocumentExportPort {
  Future<NativeFileResult<bool>> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

abstract interface class NativePreparedDocumentSharePort {
  Future<NativeFileResult<bool>> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

abstract interface class KnowledgeShareDriver {
  Future<bool> shareKnowledgeText(String text);
}

abstract interface class NativePreparedDocumentExportDriver {
  Future<bool> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

abstract interface class NativePreparedDocumentShareDriver {
  Future<bool> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  });
}

final class MethodChannelKnowledgeExportPort
    implements
        KnowledgeSharePort,
        NativePreparedDocumentExportPort,
        NativePreparedDocumentSharePort {
  const MethodChannelKnowledgeExportPort({
    KnowledgeShareDriver? shareDriver,
    NativePreparedDocumentExportDriver? documentExportDriver,
    NativePreparedDocumentShareDriver? documentShareDriver,
  }) : _shareDriver = shareDriver,
       _documentExportDriver = documentExportDriver,
       _documentShareDriver = documentShareDriver;

  final KnowledgeShareDriver? _shareDriver;
  final NativePreparedDocumentExportDriver? _documentExportDriver;
  final NativePreparedDocumentShareDriver? _documentShareDriver;

  @override
  Future<NativeFileResult<bool>> shareKnowledge(
    KnowledgeSharePayload payload,
  ) async {
    final text = payload.text.trim();
    if (text.isEmpty || text.length > 12000 || _containsPrivateLocator(text)) {
      return NativeFileResult<bool>.failure(
        _failure(
          'NATIVE_KNOWLEDGE_SHARE_INVALID',
          'Knowledge share content is invalid',
        ),
      );
    }
    try {
      final completed = await (_shareDriver ?? const _MethodChannelDriver())
          .shareKnowledgeText(text);
      return NativeFileResult<bool>.success(completed);
    } on PlatformException catch (error) {
      return NativeFileResult<bool>.failure(
        _failure(
          error.code.trim().isEmpty
              ? 'NATIVE_KNOWLEDGE_SHARE_FAILED'
              : error.code,
          error.message ?? 'Knowledge share failed',
        ),
      );
    } catch (_) {
      return NativeFileResult<bool>.failure(
        _failure('NATIVE_KNOWLEDGE_SHARE_FAILED', 'Knowledge share failed'),
      );
    }
  }

  @override
  Future<NativeFileResult<bool>> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) => _dispatchPreparedKnowledgeExport(
    opaqueExportRef: opaqueExportRef,
    displayName: displayName,
    mimeType: mimeType,
    share: false,
  );

  @override
  Future<NativeFileResult<bool>> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) => _dispatchPreparedKnowledgeExport(
    opaqueExportRef: opaqueExportRef,
    displayName: displayName,
    mimeType: mimeType,
    share: true,
  );

  Future<NativeFileResult<bool>> _dispatchPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
    required bool share,
  }) async {
    final format = _formatForReference(opaqueExportRef);
    if (format == null ||
        !_isSafeDisplayName(displayName, format) ||
        mimeType != format.mimeType) {
      return NativeFileResult<bool>.failure(
        _failure(
          'NATIVE_KNOWLEDGE_EXPORT_INVALID',
          'Prepared knowledge export metadata is invalid',
        ),
      );
    }
    try {
      final completed = share
          ? await (_documentShareDriver ?? const _MethodChannelDriver())
                .sharePreparedKnowledgeExport(
                  opaqueExportRef: opaqueExportRef,
                  displayName: displayName,
                  mimeType: mimeType,
                )
          : await (_documentExportDriver ?? const _MethodChannelDriver())
                .openPreparedKnowledgeExport(
                  opaqueExportRef: opaqueExportRef,
                  displayName: displayName,
                  mimeType: mimeType,
                );
      return NativeFileResult<bool>.success(completed);
    } on PlatformException catch (error) {
      return NativeFileResult<bool>.failure(
        _failure(
          error.code.trim().isEmpty
              ? 'NATIVE_KNOWLEDGE_EXPORT_FAILED'
              : error.code,
          error.message ?? 'Prepared knowledge export failed',
        ),
      );
    } catch (_) {
      return NativeFileResult<bool>.failure(
        _failure(
          'NATIVE_KNOWLEDGE_EXPORT_FAILED',
          'Prepared knowledge export failed',
        ),
      );
    }
  }
}

final class _MethodChannelDriver
    implements
        KnowledgeShareDriver,
        NativePreparedDocumentExportDriver,
        NativePreparedDocumentShareDriver {
  const _MethodChannelDriver();

  static const MethodChannel _channel = MethodChannel(
    'huahuoai/knowledge_export',
  );

  @override
  Future<bool> shareKnowledgeText(String text) async {
    return await _channel.invokeMethod<bool>(
          'shareKnowledgeText',
          <String, String>{'text': text},
        ) ??
        false;
  }

  @override
  Future<bool> openPreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    return await _channel
            .invokeMethod<bool>('openPreparedKnowledgeExport', <String, String>{
              'opaqueExportRef': opaqueExportRef,
              'displayName': displayName,
              'mimeType': mimeType,
            }) ??
        false;
  }

  @override
  Future<bool> sharePreparedKnowledgeExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    return await _channel.invokeMethod<bool>(
          'sharePreparedKnowledgeExport',
          <String, String>{
            'opaqueExportRef': opaqueExportRef,
            'displayName': displayName,
            'mimeType': mimeType,
          },
        ) ??
        false;
  }
}

KnowledgeExportFormat? _formatForReference(String value) {
  final text = value.trim();
  if (text != value ||
      text.contains('..') ||
      text.toLowerCase().contains('%')) {
    return null;
  }
  final match = _knowledgeExportReference.firstMatch(text);
  if (match == null) return null;
  return switch (match.group(1)?.toLowerCase()) {
    'md' => KnowledgeExportFormat.markdown,
    'pdf' => KnowledgeExportFormat.pdf,
    'zip' => KnowledgeExportFormat.archive,
    _ => null,
  };
}

bool _isSafeDisplayName(String value, KnowledgeExportFormat format) {
  final text = value.trim();
  if (text.isEmpty ||
      text != value ||
      text.length > 128 ||
      text.startsWith('.') ||
      text.endsWith('.part') ||
      text.contains('/') ||
      text.contains('\\') ||
      text.runes.any((rune) => rune < 32 || rune == 127)) {
    return false;
  }
  return text.toLowerCase().endsWith('.${format.extension}');
}

bool _containsPrivateLocator(String value) =>
    _privateLocatorPattern.hasMatch(value);

AppFailure _failure(String code, String message) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: message,
    userMessageKey: 'knowledge.export.$code',
    recoveryActions: const <String>['retry'],
  );
}

final RegExp _knowledgeExportReference = RegExp(
  r'^app-private-export://knowledge/cache/export-[A-Za-z0-9_-]{1,80}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.(md|pdf|zip)$',
  caseSensitive: false,
);

final RegExp _privateLocatorPattern = RegExp(
  r'(?:(?:file|app-private(?:-export)?):/{1,3}|/(?:Users|private/var|var/mobile|data/user|data/data)/|[A-Za-z]:\\)',
  caseSensitive: false,
);
