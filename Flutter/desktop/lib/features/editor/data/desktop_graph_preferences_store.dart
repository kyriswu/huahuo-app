import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/desktop_graph_preferences.dart';

export '../application/desktop_graph_preferences.dart';

/// Stores graph preferences separately from Markdown preview preferences.
///
/// A complete temporary file is written and flushed before the prior file is
/// replaced. Malformed or incompatible content falls back to safe defaults.
final class LocalDesktopGraphPreferencesStore
    implements DesktopGraphPreferencesStore {
  LocalDesktopGraphPreferencesStore({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const fileName = 'desktop-graph-preferences.json';
  static const _version = 1;

  final Future<Directory> Function() _supportDirectory;

  Future<Directory> _settingsDirectory() async {
    final support = await _supportDirectory();
    final settings = Directory(
      '${support.path}${Platform.pathSeparator}settings',
    );
    if (!await settings.exists()) await settings.create(recursive: true);
    return settings;
  }

  Future<File> _targetFile() async {
    final settings = await _settingsDirectory();
    return File('${settings.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<DesktopGraphPreferences> load() async {
    try {
      final target = await _targetFile();
      if (!await target.exists()) return DesktopGraphPreferences.defaults;
      final decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map) return DesktopGraphPreferences.defaults;
      final root = decoded.map((key, value) => MapEntry(key.toString(), value));
      final nested = root['graph'];
      if (nested is Map) {
        return DesktopGraphPreferences.fromJson(
          nested.map((key, value) => MapEntry(key.toString(), value)),
        );
      }

      // Accept the early single-purpose shape written by development builds.
      return DesktopGraphPreferences.fromJson(root);
    } on Object {
      return DesktopGraphPreferences.defaults;
    }
  }

  @override
  Future<void> save(DesktopGraphPreferences preferences) async {
    final target = await _targetFile();
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    final payload = <String, Object?>{
      'version': _version,
      'graph': preferences.toJson(),
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
