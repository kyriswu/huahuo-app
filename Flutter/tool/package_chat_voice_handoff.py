from __future__ import annotations

import argparse
import collections
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile


EXCLUDED_DIRECTORIES = {
    '.git', '.dart_tool', '.gradle', '.kotlin', 'build', 'Pods', '.symlinks',
    'ephemeral', 'xcuserdata', '.idea', '.vscode', 'node_modules', 'DerivedData',
    '__pycache__', '.pytest_cache', '.swiftpm', 'reports', 'exports',
}
EXCLUDED_NAMES = {
    '.DS_Store', '.flutter-plugins', '.flutter-plugins-dependencies',
    '.packages', 'local.properties', 'key.properties', 'Generated.xcconfig',
    'flutter_export_environment.sh', 'generated_config.cmake',
    'SecretKey.csv', 'AGENTS.md', 'google-services.json',
    'GoogleService-Info.plist', '.last_build_id', '.env', '.env.local',
}
EXCLUDED_SUFFIXES = {
    '.p12', '.p8', '.pfx', '.pem', '.key', '.jks', '.keystore',
    '.mobileprovision', '.provisionprofile', '.sqlite', '.sqlite3', '.db',
    '.sqlite-wal', '.sqlite-shm', '.sqlite3-wal', '.sqlite3-shm', '.log',
    '.ipa', '.apk', '.aab', '.dSYM', '.pyc', '.xcuserstate',
}
SNAPSHOT_DIRECTORIES = ('src', 'desktop', 'packages', 'vendor', 'third_party', 'tool')
CORE_DIRECTORIES = (
    'src/lib/features/chat', 'src/lib/features/transcription',
    'src/lib/features/ui_v3/presentation/chat',
)
CORE_PATHS = (
    'src/lib/features/ui_v3/presentation/v3_chat_page.dart',
    'src/lib/features/ui_v3/presentation/v3_chat_execution_process.dart',
    'src/lib/features/ui_v3/presentation/v3_chat_runtime_summary.dart',
    'src/lib/app/di/chat_providers.dart',
    'src/lib/app/bootstrap/app_providers.dart',
    'src/lib/app/bootstrap/core_provider_module.dart',
    'src/lib/core/native/voice_recorder_port.dart',
    'src/lib/features/recordings/application/monologue_recording_controller.dart',
    'src/lib/features/ingestion/application/meeting_capture_controller.dart',
    'src/lib/features/ui_v3/presentation/v3_capture_pages.dart',
    'src/lib/features/ui_v3/presentation/v3_meeting_capture_page.dart',
)
NATIVE_PATHS = (
    'src/ios/Runner/TencentLiveAsrBridge.swift',
    'src/ios/Runner/VoiceRecorderBridge.swift',
    'src/ios/Runner/AppDelegate.swift', 'src/ios/Runner/Info.plist',
    'src/ios/Runner/Runner-Bridging-Header.h',
    'src/ios/Podfile', 'src/ios/Podfile.lock',
    'src/android/app/src/main/kotlin/com/hangzhouchuda/huahuoai/TencentLiveAsrAndroidBridge.kt',
    'src/android/app/src/main/kotlin/com/hangzhouchuda/huahuoai/VoiceRecorderAndroidBridge.kt',
    'src/android/app/src/main/kotlin/com/hangzhouchuda/huahuoai/VoiceRecordingForegroundService.kt',
    'src/android/app/src/main/kotlin/com/hangzhouchuda/huahuoai/MainActivity.kt',
    'src/android/app/src/main/AndroidManifest.xml',
    'src/android/app/build.gradle.kts', 'src/android/app/proguard-rules.pro',
    'src/android/app/libs/asr-realtime-speakerSeparation-release.aar',
)
BACKEND_PATTERNS = (
    'source/internal/api/routes/chat*.go',
    'source/internal/api/routes/agent_run*.go',
    'source/internal/api/routes/realtime_asr*.go',
    'source/internal/api/routes/media_routes*.go',
    'source/internal/api/routes/auth_routes*.go',
    'source/internal/services/realtime_asr*.go',
    'source/internal/services/tencent_speech*.go',
    'source/internal/services/workspace_chat*.go',
    'source/internal/services/agent_run*.go',
    'source/internal/persistence/realtime_asr*.go',
    'source/internal/persistence/chat*.go',
    'source/internal/persistence/workspace_chat*.go',
    'source/internal/persistence/agent_run*.go',
    'source/internal/domain/chat*.go',
    'source/internal/domain/agent_run*.go',
    'source/internal/domain/media*.go',
    'source/internal/providers/tencentsts/*.go',
    'source/tests/integration/chat*.go',
    'source/tests/integration/agent_run_event_stream*.go',
    'source/tests/integration/realtime_asr*.go',
    'source/tests/unit/realtime_asr*.go',
)
TEXT_SUFFIXES = {
    '.dart', '.go', '.swift', '.kt', '.kts', '.java', '.m', '.h', '.c',
    '.md', '.txt', '.json', '.yaml', '.yml', '.xml', '.plist', '.xcconfig',
    '.properties', '.sh', '.py', '.rb', '.pro', '.pbxproj', '.entitlements',
}
SECRET_RULES = (
    ('private-key', re.compile(r'^-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', re.M)),
    ('aws-access-key', re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
    ('github-token', re.compile(r'\bgh[pousr]_[A-Za-z0-9]{25,}\b')),
    ('provider-api-key', re.compile(r'\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}\b')),
    ('credential-literal', re.compile(
        r'''(?:(?<![\w"'])(?:password|passwd|client[_-]?secret|api[_-]?key|tmpSecretKey)\s*[:=]|["'](?:password|passwd|client[_-]?secret|api[_-]?key|tmpSecretKey)["']\s*:)\s*["']([^"'\s$<{][^"']{7,})["']''',
        re.I,
    )),
)
PLACEHOLDER = re.compile(
    r'^(?:example|placeholder|change-?me|dummy|fake|redacted|fixture[-_]|tmp[-_]|test[-_]|your[-_]|build[-_]|temp(?:orary)?[-_])',
    re.I,
)


def digest(path: Path) -> str:
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def git_output(directory: Path, *arguments: str) -> str:
    result = subprocess.run(
        ['git', '-C', str(directory), *arguments], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    return result.stdout.strip() if result.returncode == 0 else 'unavailable'


def exclusion(path: Path) -> str | None:
    if path.name in EXCLUDED_NAMES or path.name.startswith('.env.'):
        return 'local/generated/private configuration'
    if path.suffix in EXCLUDED_SUFFIXES:
        return 'build artifact, signing material, log, or device data'
    if path.is_symlink():
        return 'machine-local symlink'
    return None


def gather(directory: Path, base: Path, excluded: list[dict]) -> list[Path]:
    result = []
    for current, directories, filenames in os.walk(directory):
        kept = []
        for name in sorted(directories):
            path = Path(current) / name
            if name in EXCLUDED_DIRECTORIES or path.is_symlink():
                excluded.append({'path': str(path.relative_to(base)) + '/', 'reason': 'generated/cache/output directory or symlink'})
            else:
                kept.append(name)
        directories[:] = kept
        for name in sorted(filenames):
            path = Path(current) / name
            reason = exclusion(path)
            if reason:
                excluded.append({'path': str(path.relative_to(base)), 'reason': reason})
            else:
                result.append(path)
    return result


def text_content(path: Path) -> str | None:
    if path.suffix not in TEXT_SUFFIXES and path.name not in {'Podfile', 'Podfile.lock', 'LICENSE'}:
        return None
    try:
        return path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        return None


def inspect_text(path: Path, content: str, label: str) -> tuple[list, list]:
    findings = []
    conflicts = []
    for rule_name, pattern in SECRET_RULES:
        for match in pattern.finditer(content):
            if rule_name == 'credential-literal' and PLACEHOLDER.match(match.group(1)):
                continue
            if rule_name == 'credential-literal' and any(part in {'test', 'integration_test'} for part in path.parts):
                if match.group(1) in {'12345678', 'refresh-token', 'not-a-digest', 'reviewed-real-value', 'visual-secret-key'}:
                    continue
            line = content.count('\n', 0, match.start()) + 1
            findings.append({'path': label, 'line': line, 'rule': rule_name})
    for match in re.finditer(r'^(?:<<<<<<< |>>>>>>> ).*$', content, re.M):
        conflicts.append({'path': label, 'line': content.count('\n', 0, match.start()) + 1})
    return findings, conflicts


def dart_directives(content: str) -> list[str]:
    tokens = re.compile(r'''(?:r?"""[\s\S]*?"""|r?''' + "'''[\\s\\S]*?'''" + r'''|r?"(?:\\.|[^"\\])*"|r?'(?:\\.|[^'\\])*')|//[^\n]*|/\*[\s\S]*?\*/|[A-Za-z_$][\w$]*|[^\s]''')
    lexemes = [match.group() for match in tokens.finditer(content) if not match.group().startswith(('//', '/*'))]
    result = []
    for index, token in enumerate(lexemes[:-1]):
        if token not in {'import', 'export', 'part'} or lexemes[index + 1][0] not in {'"', "'"}:
            continue
        for following in lexemes[index + 1:]:
            if following == ';':
                break
            if following[0] in {'"', "'"}:
                result.append(following[1:-1])
    return result


def dependencies(snapshot: Path) -> dict:
    manifests = sorted(snapshot.rglob('pubspec.yaml'))
    packages = {}
    path_dependencies = []
    assets = []
    missing = []
    for manifest in manifests:
        text = manifest.read_text()
        name = re.search(r'^name:\s*(\S+)', text, re.M)
        if name:
            packages[name.group(1)] = manifest.parent
        for relative in re.findall(r'^\s+path:\s*["\']?([^\s"\']+)', text, re.M):
            target = (manifest.parent / relative).resolve()
            if relative.startswith('third_party/') and not target.exists():
                target = (snapshot / relative).resolve()
            if not target.exists():
                missing.append({'source': str(manifest.relative_to(snapshot)), 'path': relative})
            else:
                path_dependencies.append({'source': str(manifest.relative_to(snapshot)), 'target': str(target.relative_to(snapshot))})
        declared = re.findall(r'^\s+-\s+((?:assets|android)/[^\n]+)', text, re.M)
        declared += re.findall(r'^\s+-?\s*asset:\s*([^\n]+)', text, re.M)
        for relative in declared:
            relative = relative.strip().strip('"\'')
            target = manifest.parent / relative
            if not target.exists():
                missing.append({'source': str(manifest.relative_to(snapshot)), 'asset': relative})
            else:
                assets.append(str(target.relative_to(snapshot)))
    root_manifest = (snapshot / 'pubspec.yaml').read_text()
    workspace_match = re.search(r'^workspace:\n((?:[ \t]+[^\n]*\n)+)', root_manifest, re.M)
    members = re.findall(r'^\s+-\s+(\S+)', workspace_match.group(1), re.M) if workspace_match else []
    for member in members:
        if not (snapshot / member / 'pubspec.yaml').is_file():
            missing.append({'workspace_member': member})
    graph = {}
    external = set()
    for source in sorted(snapshot.rglob('*.dart')):
        label = str(source.relative_to(snapshot))
        targets = set()
        for uri in dart_directives(source.read_text()):
            if uri.startswith('dart:'):
                continue
            if uri.startswith('package:'):
                name, separator, relative = uri[8:].partition('/')
                if name not in packages:
                    external.add(name)
                    continue
                target = packages[name] / 'lib' / relative
            else:
                target = source.parent / uri
            target = target.resolve()
            if not target.is_file() or not target.is_relative_to(snapshot):
                missing.append({'source': label, 'import': uri})
            else:
                targets.add(str(target.relative_to(snapshot)))
        graph[label] = sorted(targets)
    seeds = set(CORE_PATHS)
    for directory in CORE_DIRECTORIES:
        seeds.update(str(path.relative_to(snapshot)) for path in (snapshot / directory).rglob('*.dart'))
    for relative in (*seeds, *NATIVE_PATHS):
        if not (snapshot / relative).is_file():
            missing.append({'core_or_native': relative})
    if missing:
        raise RuntimeError('Missing dependencies: ' + json.dumps(missing, ensure_ascii=False, indent=2))
    closure = set()
    pending = list(seeds)
    while pending:
        current = pending.pop()
        if current not in closure:
            closure.add(current)
            pending.extend(graph.get(current, []))
    return {
        'workspace_members': members,
        'local_packages': {name: str(path.relative_to(snapshot)) for name, path in packages.items()},
        'path_dependencies': path_dependencies,
        'declared_assets': sorted(set(assets)), 'external_imported_packages': sorted(external),
        'core_entry_files': sorted(seeds), 'core_dart_dependency_closure': sorted(closure),
        'native_required_files': list(NATIVE_PATHS), 'dart_import_export_part_graph': graph,
        'missing_dependencies': missing,
    }


def sdk_snapshot() -> dict:
    executable = shutil.which('flutter')
    if executable:
        version_file = Path(executable).resolve().parent / 'cache/flutter.version.json'
        if version_file.is_file():
            return {'source': 'local SDK cached version file', **json.loads(version_file.read_text())}
    return {'source': 'unavailable; use packaged pubspec SDK constraints'}


def main() -> None:
    parser = argparse.ArgumentParser(description='Export the complete Flutter source context for chat, streaming, and live ASR.')
    parser.add_argument('--backend-root', type=Path, required=True)
    parser.add_argument('--api-docs', type=Path, required=True)
    arguments = parser.parse_args()
    flutter = Path(__file__).resolve().parents[1]
    backend = arguments.backend_root.resolve()
    api_docs = arguments.api_docs.resolve()
    for required in (backend / 'source/internal/api/routes/realtime_asr_routes.go', api_docs / '06-agent-chat-api.md'):
        if not required.is_file():
            raise FileNotFoundError(required)
    stamp = datetime.now().astimezone()
    name = 'huahuo_chat_stream_live_asr_' + stamp.strftime('%Y%m%d_%H%M%S')
    output = flutter / 'exports' / name
    if output.exists() or output.with_suffix('.zip').exists():
        raise FileExistsError(output)
    output.mkdir(parents=True)
    origins = {}
    excluded = []
    copied_sources = []
    findings = []
    conflicts = []

    def copy(source: Path, destination: str, origin: str) -> None:
        target = output / destination
        if target.exists():
            raise FileExistsError(target)
        content = text_content(source)
        if content is not None:
            secret_findings, marker_findings = inspect_text(source, content, destination)
            findings.extend(secret_findings)
            conflicts.extend(marker_findings)
        target.parent.mkdir(parents=True, exist_ok=True)
        before = digest(source)
        shutil.copy2(source, target)
        if digest(target) != before or digest(source) != before:
            raise RuntimeError('Source changed while copying: ' + destination)
        origins[destination] = {'source': origin, 'sha256': before}
        copied_sources.append((source, target, before))

    for directory in SNAPSHOT_DIRECTORIES:
        for source in gather(flutter / directory, flutter, excluded):
            relative = source.relative_to(flutter).as_posix()
            copy(source, 'Flutter/' + relative, 'workspace:Flutter/' + relative)
    for source in sorted(flutter.iterdir()):
        if source.is_file() and (source.suffix == '.md' or source.name in {'pubspec.yaml', 'pubspec.lock'}):
            copy(source, 'Flutter/' + source.name, 'workspace:Flutter/' + source.name)
    for source in gather(flutter / 'docs', flutter, excluded):
        if source.suffix == '.md':
            relative = source.relative_to(flutter).as_posix()
            copy(source, 'Flutter/' + relative, 'workspace:Flutter/' + relative)
        else:
            excluded.append({'path': str(source.relative_to(flutter)), 'reason': 'non-source documentation export/image; application assets retained separately'})
    for source in sorted((flutter / 'docs/handoff/chat_stream_live_asr').glob('*.md')):
        copy(source, source.name, 'workspace:Flutter/docs/handoff/chat_stream_live_asr/' + source.name)
    backend_files = set()
    for pattern in BACKEND_PATTERNS:
        backend_files.update(backend.glob(pattern))
    for source in sorted(backend_files):
        relative = source.relative_to(backend).as_posix()
        copy(source, 'backend_reference/huahuoai-all/' + relative, 'backend:' + relative)
    for source in sorted(api_docs.glob('*.md')):
        copy(source, 'backend_reference/api_docs/' + source.name, 'backend-docs:05-api/' + source.name)
    if findings:
        raise RuntimeError('Review potential credentials before delivery (values omitted): ' + json.dumps(findings, ensure_ascii=False, indent=2))
    snapshot = (output / 'Flutter').resolve()
    dependency_data = dependencies(snapshot)
    dependency_data['existing_conflict_markers'] = conflicts
    dependency_data['static_check_limits'] = 'Checks Dart directives, workspace/path dependencies, declared asset paths, and required native files; does not prove runtime or backend completeness.'
    (output / 'DEPENDENCIES.json').write_text(json.dumps(dependency_data, ensure_ascii=False, indent=2) + '\n')
    (output / 'EXCLUDED_FILES.json').write_text(json.dumps(excluded, ensure_ascii=False, indent=2) + '\n')
    core_lines = ['# 核心文件及依赖入口', '', '所有路径相对于包内 `Flutter/`；文件清单由归档 manifest 记录。', '', '## 核心入口', '']
    core_lines.extend('- `' + path + '`' for path in dependency_data['core_entry_files'])
    core_lines.extend(['', '## 递归 Dart 依赖闭包', '', '保留 import/export/part 引用；原生、动态资源及后端不由 Dart 引用闭包涵盖。', ''])
    core_lines.extend('- `' + path + '`' for path in dependency_data['core_dart_dependency_closure'])
    core_lines.extend(['', '## 原生必备文件', ''])
    core_lines.extend('- `' + path + '`' for path in NATIVE_PATHS)
    core_lines.extend(['', '## 相关测试入口', ''])
    test_files = sorted(path.relative_to(snapshot).as_posix() for path in snapshot.rglob('*') if path.is_file() and path.suffix in {'.dart', '.kt', '.swift'} and any(part in {'test', 'integration_test', 'RunnerTests'} for part in path.parts) and re.search('chat|stream|transcri|asr|voice|api_client|domain_clients', str(path), re.I))
    core_lines.extend('- `' + path + '`' for path in test_files)
    (output / 'CORE_FILES.md').write_text('\n'.join(core_lines) + '\n')
    ui_files = sorted(path for path in dependency_data['core_dart_dependency_closure'] if '/presentation/' in path or path.startswith(('src/lib/shared/', 'packages/huahuo_editor/')))
    ui_lines = ['# 聊一聊 UI 源码', '', 'UI 已直接复制进 `Flutter/`，与原工程目录一致，没有只打包逻辑层。', '', '## 页面和共享 UI 依赖', '']
    ui_lines.extend('- `Flutter/' + path + '`' for path in ui_files)
    ui_lines.extend(['', '## 素材和配置', '', '- `Flutter/src/assets/`：全部图片、字体和应用素材。', '- `Flutter/src/pubspec.yaml`：完整资源/字体声明。', '- `Flutter/src/test/features/chat/`：聊天 UI 测试及 golden 图片。', '- `Flutter/src/lib/app/navigation/`：路由和导航依赖。', '', '为避免漏项，相关 dialog、sheet、历史菜单、输入控件、Markdown 渲染、主题、图标依赖和包内其他页面也保留在完整源码中。'])
    (output / 'CHAT_UI_FILES.md').write_text('\n'.join(ui_lines) + '\n')
    counts = collections.Counter(destination.split('/')[1] for destination in origins if destination.startswith('Flutter/'))
    conflict_paths = sorted({item['path'] for item in conflicts})
    report = [
        '# 打包与完整性报告', '',
        f'- 打包时间：{stamp.isoformat()}',
        f'- 来源：当前工作目录，Git HEAD `{git_output(flutter.parent, "rev-parse", "HEAD")}`；保留已有未提交修改。',
        f'- 原样复制文件：{len(origins)}；相关后端实现参考：{len(backend_files)}。',
        f'- Dart 文件扫描：{len(dependency_data["dart_import_export_part_graph"])}；核心递归闭包：{len(dependency_data["core_dart_dependency_closure"])}。',
        f'- 工作区成员：{len(dependency_data["workspace_members"])}；本地 package：{len(dependency_data["local_packages"])}。',
        '- 缺失 Dart 引用/路径依赖/声明资源/原生必备文件：0。',
        '- 所有复制文件经来源和目标 SHA-256 比对；源码有并发修改时打包失败。',
        '- 全部候选文本扫描高置信私钥/令牌和密码字面量；无待审核命中。不替代专业数据泄露审计。',
        '- 排除构建缓存、Pods、机器配置、签名/环境凭据、设备数据/日志；排除记录见 `EXCLUDED_FILES.json`。',
        '- 保留 AAR、vendor 原生 SDK、字体图片、golden 和测试资源；第三方 SDK 的使用授权需接收方确认。',
        '- `MANIFEST.json` 记录除自身与 `SHA256SUMS.txt` 外的所有交付文件；`SHA256SUMS.txt` 校验除自身以外的所有文件。',
        '- 打包器完成时校验 ZIP CRC、ZIP 文件清单和归档逐文件 SHA-256，并在 ZIP 旁生成整体 SHA-256。',
        '- 没有运行完整 Flutter 测试、没有启动模拟器、没有进行真实网络/ASR/模型或后端部署验证。',
        '', '## Flutter 源文件覆盖分组', '',
    ]
    report.extend(f'- `{group}`：{count} 文件' for group, count in sorted(counts.items()))
    report.extend(['', '## 原有文档冲突', '', '以下是原文保留的既有合并标记，不是本次新增业务冲突。迁移时以当前实现/测试核对，必要时请接口负责人确认。', ''])
    report.extend('- `' + path + '`' for path in conflict_paths)
    report.extend(['', '文档中旧版 realtime-ASR 描述另见 `BACKEND_CONTRACT.md`，不要把它理解为当前实现不支持实时识别。', '', '## 未提供', '', '后端完整工程及部署配置、生产账号/凭据、iOS/Android 签名、Flutter SDK、pub/Pods 下载缓存和真实设备数据均不属于此源码交接包。'])
    (output / 'PACKAGING_REPORT.md').write_text('\n'.join(report) + '\n')
    paths = {path.relative_to(output).as_posix() for path in output.rglob('*') if path.is_file()}
    paths.update({'MANIFEST.json', 'SHA256SUMS.txt'})
    manifest_entries = []
    for path in sorted(output.rglob('*')):
        if path.is_file():
            relative = path.relative_to(output).as_posix()
            manifest_entries.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': digest(path), 'origin': origins.get(relative, {}).get('source', 'generated-handoff-metadata')})
    manifest = {
        'created_at': stamp.isoformat(), 'scope': 'complete Flutter source context; bounded non-standalone backend references',
        'working_tree_snapshot': True,
        'flutter_git_head': git_output(flutter.parent, 'rev-parse', 'HEAD'),
        'flutter_working_tree_status': git_output(flutter.parent, 'status', '--short', '--', 'Flutter'),
        'backend_git_head': git_output(backend, 'rev-parse', 'HEAD'),
        'local_sdk': sdk_snapshot(), 'file_count_excluding_manifest_and_checksum_file': len(manifest_entries),
        'files': manifest_entries,
    }
    (output / 'MANIFEST.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    checksum_paths = sorted(path for path in output.rglob('*') if path.is_file())
    checksums = {path.relative_to(output).as_posix(): digest(path) for path in checksum_paths}
    (output / 'SHA256SUMS.txt').write_text(''.join(value + '  ' + path + '\n' for path, value in checksums.items()))
    checksums['SHA256SUMS.txt'] = digest(output / 'SHA256SUMS.txt')
    for source, target, expected in copied_sources:
        if digest(source) != expected or digest(target) != expected:
            raise RuntimeError('Source changed during export: ' + str(source))
    archive_path = output.with_suffix('.zip')
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(output.rglob('*')):
            if path.is_file():
                archive.write(path, name + '/' + path.relative_to(output).as_posix())
    with zipfile.ZipFile(archive_path) as archive:
        bad = archive.testzip()
        if bad:
            raise RuntimeError('ZIP CRC failed: ' + bad)
        if set(archive.namelist()) != {name + '/' + path for path in checksums}:
            raise RuntimeError('ZIP file inventory mismatch')
        for path, expected in checksums.items():
            with archive.open(name + '/' + path) as handle:
                if hashlib.file_digest(handle, 'sha256').hexdigest() != expected:
                    raise RuntimeError('ZIP SHA-256 failed: ' + path)
    archive_hash = digest(archive_path)
    archive_path.with_suffix('.zip.sha256').write_text(archive_hash + '  ' + archive_path.name + '\n')
    print(json.dumps({'archive': str(archive_path), 'directory': str(output), 'archive_bytes': archive_path.stat().st_size, 'archive_sha256': archive_hash, 'delivered_files': len(checksums), 'dart_files_checked': len(dependency_data['dart_import_export_part_graph']), 'core_dependency_files': len(dependency_data['core_dart_dependency_closure']), 'missing_dependencies': 0, 'zip_crc_and_hashes': 'passed'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
