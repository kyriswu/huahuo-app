import 'dart:convert';
import 'dart:io';

final class SecretFinding {
  const SecretFinding({
    required this.path,
    required this.line,
    required this.ruleId,
  });

  final String path;
  final int line;
  final String ruleId;

  @override
  String toString() => '$path:$line [$ruleId]';
}

final class _SecretRule {
  const _SecretRule(this.id, this.pattern, {this.literalGroup});

  final String id;
  final RegExp pattern;
  final int? literalGroup;
}

final _rules = <_SecretRule>[
  _SecretRule(
    'private-key',
    RegExp(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
  ),
  _SecretRule('aws-access-key', RegExp(r'\bAKIA[0-9A-Z]{16}\b')),
  _SecretRule('github-token', RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b')),
  _SecretRule(
    'credential-literal',
    RegExp(
      r'''\b(?:password|passwd|client[_-]?secret|api[_-]?key)\b\s*[:=]\s*["']([^"'$\s<{][^"']{7,})["']''',
      caseSensitive: false,
    ),
    literalGroup: 1,
  ),
];

final _placeholder = RegExp(
  r'^(?:example|placeholder|change-?me|dummy|fake|redacted|test[-_]|your[-_])',
  caseSensitive: false,
);

List<SecretFinding> findSecretFindings(String path, String content) {
  final findings = <SecretFinding>[];
  final lines = const LineSplitter().convert(content);
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    if (line.contains('secret-scan: allow')) continue;
    for (final rule in _rules) {
      final match = rule.pattern.firstMatch(line);
      if (match == null) continue;
      final literal = rule.literalGroup == null
          ? null
          : match.group(rule.literalGroup!);
      if (literal != null && _placeholder.hasMatch(literal)) continue;
      findings.add(SecretFinding(path: path, line: index + 1, ruleId: rule.id));
    }
  }
  return findings;
}

Future<List<SecretFinding>> scanFlutterWorkspace({
  String? repositoryRoot,
}) async {
  final root = repositoryRoot ?? await _gitRoot();
  final result = await Process.run('git', <String>[
    '-C',
    root,
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
    'Flutter',
  ]);
  if (result.exitCode != 0) {
    throw StateError('SECRET_SCAN_FILE_DISCOVERY_FAILED');
  }
  final paths =
      (result.stdout as String)
          .split('\u0000')
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  final findings = <SecretFinding>[];
  for (final path in paths) {
    if (_ignoredPath(path)) continue;
    final file = File('$root/$path');
    if (!file.existsSync() || file.lengthSync() > 2 * 1024 * 1024) continue;
    final content = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    findings.addAll(findSecretFindings(path, content));
  }
  return findings;
}

Future<String> _gitRoot() async {
  final result = await Process.run('git', <String>[
    'rev-parse',
    '--show-toplevel',
  ]);
  if (result.exitCode != 0) throw StateError('SECRET_SCAN_GIT_ROOT_FAILED');
  return (result.stdout as String).trim();
}

bool _ignoredPath(String path) {
  if (path.contains('/.dart_tool/') || path.contains('/build/')) return true;
  const binaryExtensions = <String>{
    '.a',
    '.apk',
    '.dylib',
    '.gif',
    '.ico',
    '.jpeg',
    '.jpg',
    '.mp3',
    '.mp4',
    '.pdf',
    '.png',
    '.so',
    '.ttf',
    '.webp',
    '.zip',
  };
  final lower = path.toLowerCase();
  return binaryExtensions.any(lower.endsWith);
}

Future<void> main() async {
  final findings = await scanFlutterWorkspace();
  if (findings.isEmpty) {
    stdout.writeln('Secret scan passed for Flutter/.');
    return;
  }
  stderr.writeln(
    'Secret scan found ${findings.length} high-confidence item(s):',
  );
  for (final finding in findings) {
    stderr.writeln(finding);
  }
  exitCode = 1;
}
