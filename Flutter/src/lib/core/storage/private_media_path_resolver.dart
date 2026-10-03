import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef PrivateMediaDirectoryResolver = Future<Directory> Function();

final class PrivateMediaReference {
  const PrivateMediaReference({required this.uri, required this.fileName});

  final String uri;
  final String fileName;
}

final class PrivateMediaPathResolver {
  PrivateMediaPathResolver({
    PrivateMediaDirectoryResolver? applicationSupportDirectory,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  final PrivateMediaDirectoryResolver _applicationSupportDirectory;

  PrivateMediaReference? parse(String value) {
    final text = value.trim();
    if (text.contains('..') || text.toLowerCase().contains('%2e')) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'app-private-media' ||
        uri.host != 'screen-capture' ||
        uri.pathSegments.length != 1 ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.port != 0) {
      return null;
    }
    final fileName = uri.pathSegments.single;
    if (!_safeFileName(fileName)) return null;
    return PrivateMediaReference(uri: text, fileName: fileName);
  }

  Future<Directory> screenCapturesDirectory() async {
    final root = await _applicationSupportDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}HuahuoAI'
      '${Platform.pathSeparator}ScreenCaptures',
    );
  }

  Future<File?> resolveFile(String appPrivateUri) async {
    final reference = parse(appPrivateUri);
    if (reference == null) return null;
    final directory = await screenCapturesDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}${reference.fileName}',
    );
  }

  static bool _safeFileName(String value) {
    if (value.length < 5 || value.length > 160) return false;
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.(?:mp4|m4a)$').hasMatch(value);
  }
}
