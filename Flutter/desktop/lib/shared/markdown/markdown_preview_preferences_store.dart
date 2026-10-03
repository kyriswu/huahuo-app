import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'markdown_preview_preferences.dart';

/// Durable storage for the app-wide Markdown reading preferences.
///
/// Preview preferences deliberately live outside individual Note files. A
/// document can be opened in any workspace while retaining the reader's own
/// preferred density and network policy.
abstract interface class MarkdownPreviewPreferencesStore {
  Future<MarkdownPreviewPreferences> load();

  Future<void> save(MarkdownPreviewPreferences preferences);
}

/// File-backed Markdown preview settings for the desktop app.
///
/// The layout and replacement sequence match [LocalDocumentStore]: write a
/// complete temporary file, retain a short-lived backup, then replace the
/// target. Corrupt or partially written preferences fall back to safe defaults.
final class LocalMarkdownPreviewPreferencesStore
    implements MarkdownPreviewPreferencesStore {
  LocalMarkdownPreviewPreferencesStore({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _fileName = 'desktop-preferences.json';
  static const _version = 1;

  final Future<Directory> Function() _supportDirectory;

  Future<Directory> _settingsDirectory() async {
    final support = await _supportDirectory();
    final settings = Directory(
      '${support.path}${Platform.pathSeparator}settings',
    );
    if (!settings.existsSync()) await settings.create(recursive: true);
    return settings;
  }

  Future<File> _targetFile() async {
    final settings = await _settingsDirectory();
    return File('${settings.path}${Platform.pathSeparator}$_fileName');
  }

  @override
  Future<MarkdownPreviewPreferences> load() async {
    try {
      final target = await _targetFile();
      if (!await target.exists()) return MarkdownPreviewPreferences.defaults;
      final decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map) return MarkdownPreviewPreferences.defaults;
      final root = decoded.map((key, value) => MapEntry(key.toString(), value));
      final nested = root['markdownPreview'];
      if (nested is Map) {
        return MarkdownPreviewPreferences.fromJson(
          nested.map((key, value) => MapEntry(key.toString(), value)),
        );
      }

      // Accept an early single-purpose file shape so a later envelope does
      // not invalidate preview choices already written by development builds.
      return MarkdownPreviewPreferences.fromJson(root);
    } on Object {
      return MarkdownPreviewPreferences.defaults;
    }
  }

  @override
  Future<void> save(MarkdownPreviewPreferences preferences) async {
    final target = await _targetFile();
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    final payload = <String, Object?>{
      'version': _version,
      'markdownPreview': preferences.toJson(),
    };
    await temporary.writeAsString(jsonEncode(payload), flush: true);
    if (!await target.exists()) {
      await temporary.rename(target.path);
      return;
    }

    if (await backup.exists()) await backup.delete();
    await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      await backup.delete();
    } on Object {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }
}

/// Observable Markdown preview preferences with ordered, durable writes.
///
/// Updates reach the UI immediately. Disk writes are serialized so a rapid
/// slider drag cannot let an older value overwrite the final selection.
final class MarkdownPreviewPreferencesController
    extends ValueNotifier<MarkdownPreviewPreferences> {
  MarkdownPreviewPreferencesController({
    MarkdownPreviewPreferencesStore? store,
    MarkdownPreviewPreferences initialValue =
        MarkdownPreviewPreferences.defaults,
  }) : _store = store ?? LocalMarkdownPreviewPreferencesStore(),
       super(initialValue);

  final MarkdownPreviewPreferencesStore _store;
  Future<void>? _loadFuture;
  Future<void> _saveChain = Future<void>.value();
  int _revision = 0;

  /// Loads once per controller lifetime. Safe defaults remain visible while
  /// the app-support file is being read.
  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    final revisionAtStart = _revision;
    MarkdownPreviewPreferences loaded;
    try {
      loaded = await _store.load();
    } on Object {
      loaded = MarkdownPreviewPreferences.defaults;
    }
    if (_revision == revisionAtStart) value = loaded;
  }

  Future<void> update(MarkdownPreviewPreferences preferences) {
    _revision += 1;
    if (value != preferences) value = preferences;
    return _enqueueSave(preferences);
  }

  Future<void> reset() => update(MarkdownPreviewPreferences.defaults);

  Future<void> _enqueueSave(MarkdownPreviewPreferences preferences) {
    final previous = _saveChain;
    final next = _saveAfter(previous, preferences);
    _saveChain = next;
    return next;
  }

  Future<void> _saveAfter(
    Future<void> previous,
    MarkdownPreviewPreferences preferences,
  ) async {
    try {
      await previous;
    } on Object {
      // A failed old write should not prevent a newer choice from persisting.
    }
    await _store.save(preferences);
  }
}
