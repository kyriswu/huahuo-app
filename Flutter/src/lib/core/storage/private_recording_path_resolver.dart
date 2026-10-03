import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum PrivateRecordingReferenceKind {
  localRecording,
  recordingCard,
  legacyFlutter,
}

enum PrivateRecordingPlatform { ios, android, other }

final class PrivateRecordingReference {
  const PrivateRecordingReference({
    required this.kind,
    required this.uri,
    required this.fileId,
    required this.fileName,
  });

  final PrivateRecordingReferenceKind kind;
  final String uri;
  final String fileId;
  final String fileName;
}

final class DiscoveredPrivateRecording {
  const DiscoveredPrivateRecording({
    required this.appPrivateUri,
    required this.fileName,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String appPrivateUri;
  final String fileName;
  final PrivateRecordingReferenceKind kind;
  final int sizeBytes;
  final DateTime modifiedAt;
}

typedef PrivateDirectoryResolver = Future<Directory> Function();

final class PrivateRecordingPathResolver {
  PrivateRecordingPathResolver({
    String? accountScope,
    PrivateDirectoryResolver? applicationSupportDirectory,
    PrivateDirectoryResolver? documentsDirectory,
    PrivateRecordingPlatform? platform,
  }) : _accountScope = _normalizeAccountScope(accountScope),
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _platform = platform ?? _currentPlatform();

  final String? _accountScope;
  final PrivateDirectoryResolver _applicationSupportDirectory;
  final PrivateDirectoryResolver _documentsDirectory;
  final PrivateRecordingPlatform _platform;

  /// The raw account identifier is never included in a path or URI.
  bool get hasAccountScope => _accountScope != null;

  String? get accountScope => _accountScope;

  /// Safe, irreversible directory token for a native recorder start request.
  /// It intentionally reveals neither the account ID nor a filesystem path.
  String? get nativeRecorderDirectoryScope => _accountDirectoryName;

  /// Safe directory token carried by opaque native export references.
  String? get temporaryTransferDirectoryScope => _accountDirectoryName;

  String? get _accountDirectoryName {
    final scope = _accountScope;
    if (scope == null) return null;
    return 'u-${sha256.convert(utf8.encode(scope)).toString().substring(0, 32)}';
  }

  PrivateRecordingReference? parse(String value) {
    final text = value.trim();
    final lower = text.toLowerCase();
    if (text.contains('..') || lower.contains('%2e')) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'app-private' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.port != 0) {
      return null;
    }
    if (uri.host == 'recording-card' && uri.pathSegments.length == 1) {
      final fileName = uri.pathSegments.single;
      if (!_isSafeComponent(fileName)) return null;
      return PrivateRecordingReference(
        kind: PrivateRecordingReferenceKind.recordingCard,
        uri: text,
        fileId: 'recording-card/$fileName',
        fileName: fileName,
      );
    }
    if (uri.host == 'recordings' && uri.pathSegments.length == 2) {
      final fileId = uri.pathSegments[0];
      final fileName = uri.pathSegments[1];
      if (!_isSafeComponent(fileId) || !_isSafeComponent(fileName)) return null;
      return PrivateRecordingReference(
        kind: PrivateRecordingReferenceKind.legacyFlutter,
        uri: text,
        fileId: fileId,
        fileName: fileName,
      );
    }
    if (uri.host.isNotEmpty && uri.pathSegments.isEmpty) {
      final fileId = text.substring('app-private://'.length);
      if (!_isSafeComponent(fileId)) return null;
      return PrivateRecordingReference(
        kind: PrivateRecordingReferenceKind.localRecording,
        uri: text,
        fileId: fileId,
        fileName: fileId,
      );
    }
    return null;
  }

  bool isSafe(String value, {bool allowLegacy = true}) {
    final reference = parse(value);
    return reference != null &&
        (allowLegacy ||
            reference.kind != PrivateRecordingReferenceKind.legacyFlutter);
  }

  String localUri(String fileId) {
    if (!_isSafeComponent(fileId)) {
      throw const FormatException('Unsafe private recording file id');
    }
    return 'app-private://$fileId';
  }

  String recordingCardUri(String fileName) {
    if (!_isSafeComponent(fileName)) {
      throw const FormatException('Unsafe recording-card file name');
    }
    return 'app-private://recording-card/$fileName';
  }

  Future<Directory> localRecordingsDirectory() async {
    final root = await _applicationSupportDirectory();
    final parts = _localDirectoryParts();
    return Directory(_join(root.path, parts));
  }

  Future<Directory> recordingCardDirectory() async {
    final root = await _applicationSupportDirectory();
    final parts = _recordingCardDirectoryParts();
    return Directory(_join(root.path, parts));
  }

  Future<Directory> temporaryTransfersDirectory() async {
    final root = await _applicationSupportDirectory();
    final scope = _accountDirectoryName;
    final parts = _platform == PrivateRecordingPlatform.android
        ? <String>[
            'recordings',
            if (scope != null) 'users',
            if (scope != null) scope,
            'temporary',
          ]
        : <String>[
            'HuahuoAI',
            if (scope != null) 'Users',
            if (scope != null) scope,
            'TemporaryTransfers',
          ];
    return Directory(_join(root.path, parts));
  }

  Future<File?> resolveFile(String appPrivateUri) async {
    final reference = parse(appPrivateUri);
    if (reference == null) return null;
    if (hasAccountScope &&
        reference.kind == PrivateRecordingReferenceKind.legacyFlutter) {
      return null;
    }
    final support = await _applicationSupportDirectory();
    final documents = await _documentsDirectory();
    final candidates = switch (reference.kind) {
      PrivateRecordingReferenceKind.localRecording => _localCandidates(
        support: support,
        documents: documents,
        fileName: reference.fileName,
      ),
      PrivateRecordingReferenceKind.recordingCard => _recordingCardCandidates(
        support: support,
        documents: documents,
        fileName: reference.fileName,
      ),
      PrivateRecordingReferenceKind.legacyFlutter => _legacyCandidates(
        support: support,
        documents: documents,
        fileId: reference.fileId,
        fileName: reference.fileName,
      ),
    };
    for (final file in candidates) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        if (reference.kind != PrivateRecordingReferenceKind.recordingCard ||
            file.path == candidates.first.path) {
          return file;
        }
        return _migrateRecordingCardFile(file, candidates.first);
      }
    }
    return candidates.first;
  }

  /// Resolves only the historical unscoped roots for an explicit migration.
  /// Normal authenticated reads must use [resolveFile] and cannot fall back to
  /// these candidates.
  Future<File?> resolveUnscopedFile(String appPrivateUri) async {
    final reference = parse(appPrivateUri);
    if (reference == null) return null;
    final support = await _applicationSupportDirectory();
    final documents = await _documentsDirectory();
    final candidates = switch (reference.kind) {
      PrivateRecordingReferenceKind.localRecording => _unscopedLocalCandidates(
        support: support,
        documents: documents,
        fileName: reference.fileName,
      ),
      PrivateRecordingReferenceKind.recordingCard =>
        _unscopedRecordingCardCandidates(
          support: support,
          documents: documents,
          fileName: reference.fileName,
        ),
      PrivateRecordingReferenceKind.legacyFlutter => _legacyCandidates(
        support: support,
        documents: documents,
        fileId: reference.fileId,
        fileName: reference.fileName,
      ),
    };
    for (final file in candidates) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        return file;
      }
    }
    return candidates.first;
  }

  Future<List<DiscoveredPrivateRecording>> discoverExistingRecordings() async {
    final support = await _applicationSupportDirectory();
    final documents = await _documentsDirectory();
    final roots = hasAccountScope
        ? _scopedDiscoveryRoots(support: support, documents: documents)
        : <_DiscoveryRoot>[
            for (final directory in <Directory>[
              Directory(
                _join(support.path, const <String>['HuahuoAI', 'Recordings']),
              ),
              Directory(
                _join(documents.path, const <String>['HuahuoAI', 'Recordings']),
              ),
              Directory(
                _join(support.path, const <String>['recordings', 'imports']),
              ),
              Directory(
                _join(documents.path, const <String>['recordings', 'imports']),
              ),
            ])
              _DiscoveryRoot(
                directory: directory,
                kind: PrivateRecordingReferenceKind.localRecording,
              ),
            for (final directory in <Directory>[
              Directory(
                _join(support.path, const <String>[
                  'HuahuoAI',
                  'Recordings',
                  'RecordingCard',
                ]),
              ),
              Directory(
                _join(documents.path, const <String>[
                  'HuahuoAI',
                  'Recordings',
                  'RecordingCard',
                ]),
              ),
              Directory(
                _join(support.path, const <String>[
                  'recordings',
                  'recording-card',
                ]),
              ),
              Directory(
                _join(documents.path, const <String>[
                  'recordings',
                  'recording-card',
                ]),
              ),
              Directory(
                _join(support.path, const <String>[
                  'HuahuoRecordings',
                  'RecordingCard',
                ]),
              ),
              Directory(
                _join(documents.path, const <String>[
                  'HuahuoRecordings',
                  'RecordingCard',
                ]),
              ),
              Directory(_join(support.path, const <String>['recordings'])),
              Directory(_join(documents.path, const <String>['recordings'])),
            ])
              _DiscoveryRoot(
                directory: directory,
                kind: PrivateRecordingReferenceKind.recordingCard,
              ),
            for (final directory in <Directory>[
              Directory(
                _join(support.path, const <String>['recordings', 'library']),
              ),
              Directory(
                _join(documents.path, const <String>['recordings', 'library']),
              ),
            ])
              _DiscoveryRoot(
                directory: directory,
                kind: PrivateRecordingReferenceKind.legacyFlutter,
                nested: true,
              ),
          ];
    final byUri = <String, DiscoveredPrivateRecording>{};
    final seenPaths = <String>{};
    for (final root in roots) {
      await _discoverRoot(root, byUri: byUri, seenPaths: seenPaths);
    }
    final result = byUri.values.toList()
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return List<DiscoveredPrivateRecording>.unmodifiable(result);
  }

  String canonicalUriForLegacy(
    PrivateRecordingReference legacy, {
    required bool recordingCard,
  }) {
    if (legacy.kind != PrivateRecordingReferenceKind.legacyFlutter) {
      return legacy.uri;
    }
    return recordingCard
        ? recordingCardUri('${legacy.fileId}-${legacy.fileName}')
        : localUri('${legacy.fileId}-${legacy.fileName}');
  }

  List<_DiscoveryRoot> _scopedDiscoveryRoots({
    required Directory support,
    required Directory documents,
  }) {
    return <_DiscoveryRoot>[
      for (final root in <Directory>[support, documents])
        _DiscoveryRoot(
          directory: Directory(_join(root.path, _localDirectoryParts())),
          kind: PrivateRecordingReferenceKind.localRecording,
        ),
      for (final root in <Directory>[support, documents])
        _DiscoveryRoot(
          directory: Directory(
            _join(root.path, _recordingCardDirectoryParts()),
          ),
          kind: PrivateRecordingReferenceKind.recordingCard,
        ),
    ];
  }

  List<File> _localCandidates({
    required Directory support,
    required Directory documents,
    required String fileName,
  }) {
    if (hasAccountScope) {
      return <File>[
        for (final root in <Directory>[support, documents])
          File(_join(root.path, <String>[..._localDirectoryParts(), fileName])),
      ];
    }
    return _unscopedLocalCandidates(
      support: support,
      documents: documents,
      fileName: fileName,
    );
  }

  List<File> _unscopedLocalCandidates({
    required Directory support,
    required Directory documents,
    required String fileName,
  }) {
    final roots = <Directory>[support, documents];
    final rn = <File>[
      for (final root in roots)
        File(_join(root.path, <String>['HuahuoAI', 'Recordings', fileName])),
    ];
    final android = <File>[
      for (final root in roots)
        File(_join(root.path, <String>['recordings', 'imports', fileName])),
    ];
    return _platform == PrivateRecordingPlatform.android
        ? <File>[...android, ...rn]
        : <File>[...rn, ...android];
  }

  List<File> _recordingCardCandidates({
    required Directory support,
    required Directory documents,
    required String fileName,
  }) {
    if (hasAccountScope) {
      return <File>[
        for (final root in <Directory>[support, documents])
          File(
            _join(root.path, <String>[
              ..._recordingCardDirectoryParts(),
              fileName,
            ]),
          ),
      ];
    }
    return _unscopedRecordingCardCandidates(
      support: support,
      documents: documents,
      fileName: fileName,
    );
  }

  List<File> _unscopedRecordingCardCandidates({
    required Directory support,
    required Directory documents,
    required String fileName,
  }) {
    final roots = <Directory>[support, documents];
    final canonicalApple = <File>[
      for (final root in roots)
        File(
          _join(root.path, <String>[
            'HuahuoAI',
            'Recordings',
            'RecordingCard',
            fileName,
          ]),
        ),
    ];
    final canonicalAndroid = <File>[
      for (final root in roots)
        File(
          _join(root.path, <String>['recordings', 'recording-card', fileName]),
        ),
    ];
    final rn = <File>[
      for (final root in roots)
        File(
          _join(root.path, <String>[
            'HuahuoRecordings',
            'RecordingCard',
            fileName,
          ]),
        ),
    ];
    final android = <File>[
      for (final root in roots)
        File(_join(root.path, <String>['recordings', fileName])),
    ];
    return _platform == PrivateRecordingPlatform.android
        ? <File>[...canonicalAndroid, ...android, ...canonicalApple, ...rn]
        : <File>[...canonicalApple, ...rn, ...canonicalAndroid, ...android];
  }

  List<String> _localDirectoryParts() {
    final scope = _accountDirectoryName;
    return _platform == PrivateRecordingPlatform.android
        ? <String>[
            'recordings',
            if (scope != null) 'users',
            if (scope != null) scope,
            'imports',
          ]
        : <String>[
            'HuahuoAI',
            if (scope != null) 'Users',
            if (scope != null) scope,
            'Recordings',
          ];
  }

  List<String> _recordingCardDirectoryParts() {
    final scope = _accountDirectoryName;
    return _platform == PrivateRecordingPlatform.android
        ? <String>[
            'recordings',
            if (scope != null) 'users',
            if (scope != null) scope,
            'recording-card',
          ]
        : <String>[
            'HuahuoAI',
            if (scope != null) 'Users',
            if (scope != null) scope,
            'Recordings',
            'RecordingCard',
          ];
  }

  Future<File> _migrateRecordingCardFile(File source, File target) async {
    File? temporary;
    try {
      await target.parent.create(recursive: true);
      if (await target.exists()) return target;
      temporary = File('${target.path}.tmp');
      if (await temporary.exists()) await temporary.delete();
      final sourceSize = await source.length();
      if (sourceSize <= 0) return source;
      await source.openRead().pipe(temporary.openWrite());
      if (await temporary.length() != sourceSize) {
        await temporary.delete();
        return source;
      }
      await temporary.rename(target.path);
      try {
        await source.delete();
      } on FileSystemException {
        // The canonical copy is already durable; stale legacy cleanup can wait.
      }
      return target;
    } on FileSystemException {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      return source;
    }
  }

  List<File> _legacyCandidates({
    required Directory support,
    required Directory documents,
    required String fileId,
    required String fileName,
  }) {
    final roots = _platform == PrivateRecordingPlatform.android
        ? <Directory>[support, documents]
        : <Directory>[documents, support];
    return <File>[
      for (final root in roots)
        File(
          _join(root.path, <String>['recordings', 'library', fileId, fileName]),
        ),
    ];
  }

  Future<void> _discoverRoot(
    _DiscoveryRoot root, {
    required Map<String, DiscoveredPrivateRecording> byUri,
    required Set<String> seenPaths,
  }) async {
    if (!await root.directory.exists()) return;
    try {
      await for (final entity in root.directory.list(followLinks: false)) {
        if (root.nested && entity is Directory) {
          final fileId = entity.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .lastOrNull;
          if (fileId == null || !_isSafeComponent(fileId)) continue;
          await for (final child in entity.list(followLinks: false)) {
            if (child is! File) continue;
            await _registerDiscoveredFile(
              child,
              kind: root.kind,
              legacyFileId: fileId,
              byUri: byUri,
              seenPaths: seenPaths,
            );
          }
          continue;
        }
        if (entity is! File) continue;
        await _registerDiscoveredFile(
          entity,
          kind: root.kind,
          byUri: byUri,
          seenPaths: seenPaths,
        );
      }
    } on FileSystemException {
      return;
    }
  }

  Future<void> _registerDiscoveredFile(
    File file, {
    required PrivateRecordingReferenceKind kind,
    required Map<String, DiscoveredPrivateRecording> byUri,
    required Set<String> seenPaths,
    String? legacyFileId,
  }) async {
    if (!seenPaths.add(file.path)) return;
    final fileName = file.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    if (fileName == null ||
        !_isSafeComponent(fileName) ||
        !_isSupportedAudioFile(fileName)) {
      return;
    }
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return;
    final uri = switch (kind) {
      PrivateRecordingReferenceKind.localRecording => localUri(fileName),
      PrivateRecordingReferenceKind.recordingCard => recordingCardUri(fileName),
      PrivateRecordingReferenceKind.legacyFlutter =>
        'app-private://recordings/$legacyFileId/$fileName',
    };
    byUri.putIfAbsent(
      uri,
      () => DiscoveredPrivateRecording(
        appPrivateUri: uri,
        fileName: fileName,
        kind: kind,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      ),
    );
  }
}

final class _DiscoveryRoot {
  const _DiscoveryRoot({
    required this.directory,
    required this.kind,
    this.nested = false,
  });

  final Directory directory;
  final PrivateRecordingReferenceKind kind;
  final bool nested;
}

bool isSafeAppPrivateRecordingUri(String value, {bool allowLegacy = true}) {
  return PrivateRecordingPathResolver().isSafe(value, allowLegacy: allowLegacy);
}

bool _isSafeComponent(String value) {
  return value.isNotEmpty &&
      value.length <= 160 &&
      value != '.' &&
      value != '..' &&
      !value.endsWith('.part') &&
      !value.endsWith('.tmp') &&
      !value.contains('..') &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);
}

bool _isSupportedAudioFile(String value) {
  final lower = value.toLowerCase();
  return const <String>[
    '.mp3',
    '.m4a',
    '.mp4',
    '.wav',
    '.opus',
  ].any(lower.endsWith);
}

String? _normalizeAccountScope(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > 256 || normalized.contains('\u0000')) {
    throw ArgumentError.value(value, 'accountScope', 'is unsafe');
  }
  return normalized;
}

PrivateRecordingPlatform _currentPlatform() {
  if (Platform.isIOS) return PrivateRecordingPlatform.ios;
  if (Platform.isAndroid) return PrivateRecordingPlatform.android;
  return PrivateRecordingPlatform.other;
}

String _join(String base, List<String> parts) {
  return <String>[base, ...parts].join(Platform.pathSeparator);
}
