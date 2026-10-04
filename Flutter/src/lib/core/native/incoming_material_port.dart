import 'dart:async';

import 'package:flutter/services.dart';

import 'package:huahuo_api/huahuo_api.dart';
import 'document_import_format.dart';
import 'native_file_port.dart';

enum IncomingMaterialKind { audio, document }

enum IncomingMaterialOrigin { open, send, sendMultiple }

final class IncomingMaterialDraft {
  const IncomingMaterialDraft({
    required this.opaqueRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    required this.origin,
    required this.sourcePath,
    required this.contentHash,
    this.sourceIdentifier,
  });

  final String opaqueRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final IncomingMaterialKind kind;
  final IncomingMaterialOrigin origin;
  final String sourcePath;
  final String contentHash;
  final String? sourceIdentifier;

  String get fileExtension {
    final dot = displayName.lastIndexOf('.');
    if (dot < 0 || dot == displayName.length - 1) return '';
    return displayName.substring(dot + 1).toLowerCase();
  }

  PickedAudioFile toPickedAudio() => PickedAudioFile(
    pickerRef: opaqueRef,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sourcePath: sourcePath,
    sourceIdentifier: sourceIdentifier,
    contentHash: contentHash,
  );

  PickedDocumentFile toPickedDocument() => PickedDocumentFile(
    pickerRef: opaqueRef,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sourcePath: sourcePath,
    sourceIdentifier: sourceIdentifier,
    contentHash: contentHash,
  );
}

abstract interface class IncomingMaterialPort {
  Stream<void> get pendingMaterials;

  Future<NativeFileResult<List<IncomingMaterialDraft>>>
  consumePendingMaterials();

  Future<NativeFileResult<List<String>>> consumePendingMaterialErrors();

  Future<NativeFileResult<bool>> acknowledgePendingMaterials(
    Iterable<String> opaqueRefs, {
    bool discardFiles = true,
  });
}

final class MethodChannelIncomingMaterialPort implements IncomingMaterialPort {
  MethodChannelIncomingMaterialPort({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('huahuoai/native_file'),
       _eventChannel =
           eventChannel ?? const EventChannel('huahuoai/native_file/incoming');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  late final Stream<void> _pendingMaterials = _eventChannel
      .receiveBroadcastStream()
      .where((event) => event == 'pending')
      .map((_) {});

  @override
  Stream<void> get pendingMaterials => _pendingMaterials;

  @override
  Future<NativeFileResult<List<IncomingMaterialDraft>>>
  consumePendingMaterials() async {
    try {
      final raw = await _methodChannel.invokeListMethod<Object?>(
        'consumeIncomingMaterials',
      );
      if (raw == null || raw.isEmpty) {
        return NativeFileResult<List<IncomingMaterialDraft>>.success(
          const <IncomingMaterialDraft>[],
        );
      }
      final drafts = <IncomingMaterialDraft>[];
      for (final item in raw) {
        final draft = _draftFromNative(item);
        if (draft == null) {
          return NativeFileResult<List<IncomingMaterialDraft>>.failure(
            _incomingFailure(
              'INCOMING_MATERIAL_PAYLOAD_INVALID',
              'System-delivered file metadata was invalid',
            ),
          );
        }
        drafts.add(draft);
      }
      return NativeFileResult<List<IncomingMaterialDraft>>.success(
        List<IncomingMaterialDraft>.unmodifiable(drafts),
      );
    } on PlatformException catch (error) {
      return NativeFileResult<List<IncomingMaterialDraft>>.failure(
        _incomingFailure(
          error.code.isEmpty ? 'INCOMING_MATERIAL_NATIVE_FAILED' : error.code,
          error.message ?? 'System-delivered files could not be prepared',
        ),
      );
    } on MissingPluginException {
      return NativeFileResult<List<IncomingMaterialDraft>>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_UNAVAILABLE',
          'System file handoff is unavailable',
        ),
      );
    } on Object {
      return NativeFileResult<List<IncomingMaterialDraft>>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_NATIVE_FAILED',
          'System-delivered files could not be prepared',
        ),
      );
    }
  }

  @override
  Future<NativeFileResult<List<String>>> consumePendingMaterialErrors() async {
    try {
      final raw = await _methodChannel.invokeListMethod<Object?>(
        'consumeIncomingMaterialErrors',
      );
      if (raw == null || raw.isEmpty) {
        return NativeFileResult<List<String>>.success(const <String>[]);
      }
      final codes = <String>[];
      for (final value in raw) {
        if (value is! String || !_incomingMaterialErrorCodes.contains(value)) {
          return NativeFileResult<List<String>>.failure(
            _incomingFailure(
              'INCOMING_MATERIAL_ERROR_PAYLOAD_INVALID',
              'System-delivered file failure metadata was invalid',
            ),
          );
        }
        codes.add(value);
      }
      return NativeFileResult<List<String>>.success(
        List<String>.unmodifiable(codes),
      );
    } on PlatformException catch (error) {
      return NativeFileResult<List<String>>.failure(
        _incomingFailure(
          error.code.isEmpty
              ? 'INCOMING_MATERIAL_ERROR_READ_FAILED'
              : error.code,
          error.message ?? 'System-delivered file failures could not be read',
        ),
      );
    } on MissingPluginException {
      return NativeFileResult<List<String>>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_UNAVAILABLE',
          'System file handoff is unavailable',
        ),
      );
    } on Object {
      return NativeFileResult<List<String>>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_ERROR_READ_FAILED',
          'System-delivered file failures could not be read',
        ),
      );
    }
  }

  @override
  Future<NativeFileResult<bool>> acknowledgePendingMaterials(
    Iterable<String> opaqueRefs, {
    bool discardFiles = true,
  }) async {
    final refs = opaqueRefs
        .map((value) => value.trim())
        .where(
          (value) => RegExp(
            r'^incoming-material://[A-Za-z0-9-]{1,96}$',
          ).hasMatch(value),
        )
        .toSet()
        .toList(growable: false);
    if (refs.isEmpty) {
      return NativeFileResult<bool>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_ACK_INVALID',
          'No valid incoming material was acknowledged',
        ),
      );
    }
    try {
      final acknowledged = await _methodChannel.invokeMethod<bool>(
        'acknowledgeIncomingMaterials',
        <String, Object>{'opaqueRefs': refs, 'discardFiles': discardFiles},
      );
      if (acknowledged != true) {
        return NativeFileResult<bool>.failure(
          _incomingFailure(
            'INCOMING_MATERIAL_ACK_FAILED',
            'System-delivered files could not be acknowledged',
          ),
        );
      }
      return NativeFileResult<bool>.success(true);
    } on PlatformException catch (error) {
      return NativeFileResult<bool>.failure(
        _incomingFailure(
          error.code.isEmpty ? 'INCOMING_MATERIAL_ACK_FAILED' : error.code,
          error.message ?? 'System-delivered files could not be acknowledged',
        ),
      );
    } on MissingPluginException {
      return NativeFileResult<bool>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_UNAVAILABLE',
          'System file handoff is unavailable',
        ),
      );
    } on Object {
      return NativeFileResult<bool>.failure(
        _incomingFailure(
          'INCOMING_MATERIAL_ACK_FAILED',
          'System-delivered files could not be acknowledged',
        ),
      );
    }
  }
}

const _audioExtensions = <String>{'mp3', 'm4a', 'mp4', 'wav', 'opus'};
const _incomingMaterialErrorCodes = <String>{
  'INCOMING_MATERIAL_EMPTY',
  'INCOMING_MATERIAL_FORMAT_UNSUPPORTED',
  'INCOMING_MATERIAL_PERMISSION_DENIED',
  'INCOMING_MATERIAL_TOO_LARGE',
  'INCOMING_MATERIAL_UNREADABLE',
};

IncomingMaterialDraft? _draftFromNative(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<Object?, Object?>();
  final opaqueRef = map['opaqueRef'];
  final displayName = map['displayName'];
  final mimeType = map['mimeType'];
  final sizeBytes = map['sizeBytes'];
  final sourcePath = map['sourcePath'];
  final contentHash = map['contentHash'];
  final sourceIdentifier = map['sourceIdentifier'];
  final rawOrigin = map['origin'];
  if (opaqueRef is! String ||
      !opaqueRef.startsWith('incoming-material://') ||
      displayName is! String ||
      displayName.trim().isEmpty ||
      displayName.length > 240 ||
      mimeType is! String ||
      mimeType.trim().isEmpty ||
      sizeBytes is! num ||
      sizeBytes.toInt() <= 0 ||
      sourcePath is! String ||
      sourcePath.trim().isEmpty ||
      contentHash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
    return null;
  }
  final dot = displayName.lastIndexOf('.');
  final extension = dot < 0 ? '' : displayName.substring(dot + 1).toLowerCase();
  final documentFormat = DocumentImportFormat.fromExtension(extension);
  final kind = _audioExtensions.contains(extension)
      ? IncomingMaterialKind.audio
      : documentFormat != null
      ? IncomingMaterialKind.document
      : null;
  final origin = switch (rawOrigin) {
    'open' => IncomingMaterialOrigin.open,
    'send' => IncomingMaterialOrigin.send,
    'sendMultiple' => IncomingMaterialOrigin.sendMultiple,
    _ => null,
  };
  if (kind == null || origin == null) return null;
  final normalizedMime = mimeType.toLowerCase();
  if (kind == IncomingMaterialKind.audio &&
      !normalizedMime.startsWith('audio/') &&
      normalizedMime != 'application/octet-stream') {
    return null;
  }
  if (kind == IncomingMaterialKind.audio &&
      !_audioMimeMatchesExtension(extension, normalizedMime)) {
    return null;
  }
  return IncomingMaterialDraft(
    opaqueRef: opaqueRef,
    displayName: displayName,
    // Incoming document MIME is intentionally derived from the verified
    // filename. Share sheets regularly degrade it to application/octet-stream.
    mimeType: documentFormat?.mimeType ?? normalizedMime,
    sizeBytes: sizeBytes.toInt(),
    kind: kind,
    origin: origin,
    sourcePath: sourcePath,
    contentHash: contentHash,
    sourceIdentifier:
        sourceIdentifier is String && sourceIdentifier.trim().isNotEmpty
        ? sourceIdentifier
        : null,
  );
}

bool _audioMimeMatchesExtension(String extension, String mimeType) {
  if (mimeType == 'application/octet-stream') return true;
  return switch (extension) {
    'mp3' => mimeType == 'audio/mpeg' || mimeType == 'audio/mp3',
    'm4a' || 'mp4' => mimeType == 'audio/mp4' || mimeType == 'audio/x-m4a',
    'wav' => mimeType == 'audio/wav' || mimeType == 'audio/x-wav',
    'opus' => mimeType == 'audio/opus' || mimeType == 'audio/ogg',
    _ => false,
  };
}

AppFailure _incomingFailure(String code, String message) => AppFailure(
  code: code,
  category: AppFailureCategory.storage,
  message: message,
  userMessageKey: 'incoming.material.failed',
  isRetryable: true,
);
