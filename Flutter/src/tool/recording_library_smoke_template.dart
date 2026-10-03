import 'dart:io';

void main(List<String> args) {
  final outputPath = _outputPath(args);
  if (outputPath == _invalidArgs) {
    stderr.writeln(
      'Usage: dart run tool/recording_library_smoke_template.dart [--output <path>]',
    );
    exitCode = 64;
    return;
  }

  final template = _template(DateTime.now().toUtc());
  if (outputPath == null) {
    stdout.write(template);
    return;
  }

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(template);
  stdout.writeln('Recording library smoke template written to ${output.path}');
}

String? _outputPath(List<String> args) {
  if (args.isEmpty) return null;
  if (args.length == 2 &&
      args.first == '--output' &&
      args.last.trim().isNotEmpty) {
    return args.last;
  }
  return _invalidArgs;
}

String _template(DateTime generatedAt) {
  return '''
# Phase 5 Recording Library Mobile Smoke Record

status: pending
generated_at_utc: ${generatedAt.toIso8601String()}

This record must be completed on a real iOS or Android device before any
file-picking, private-storage, or export-cache capability is marked aligned.
Do not change `status` to passed without attaching concrete device evidence.

## Device

- Platform:
- OS version:
- App build:
- Tester:
- Date:

## Checks

- [ ] Open the Flutter recording library route from Home.
- [ ] Pick one supported audio file with the platform file picker.
- [ ] Confirm the imported row appears in the library list.
- [ ] Confirm no real filesystem path, `file://` URI, token, workspace, or provider text is visible.
- [ ] Restart the app and confirm recording metadata is restored.
- [ ] Rename the recording and confirm the new name is shown after refresh.
- [ ] Add tags and confirm search matches name/tags.
- [ ] Favorite/unfavorite the row and confirm counts update.
- [ ] Move the row to recycle bin, restore it, then permanently delete it.
- [ ] Confirm permanent delete removes the private audio file or makes it unavailable.
- [ ] Prepare export and confirm the UI shows only display name/size, not the opaque export ref or real path.
- [ ] Try importing a `.part`/unsafe file reference if the platform allows selecting it; confirm failure does not create a row.

## Evidence

- Screen recording or screenshots:
- Device logs, redacted:
- Notes:

## Result

- [ ] passed
- [ ] failed

Failure reason:
''';
}

const _invalidArgs = '\u0000invalid-args';
