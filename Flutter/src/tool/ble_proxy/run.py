#!/usr/bin/env python3
"""Local, explicit BLE relay launcher. No third-party Python dependencies."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import secrets
import select
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'ios' / 'Runner'
HERE = Path(__file__).resolve().parent
BUILD = ROOT / 'build' / 'ble_proxy'
BUNDLE = 'com.hangzhouchuda.huahuoai'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def require_formal_app(app):
    with (app / 'Info.plist').open('rb') as stream:
        target = plistlib.load(stream).get('HuahuoFlutterEntrypoint', '')
    if target != 'lib/main.dart' and target != str(ROOT / 'lib' / 'main.dart'):
        raise RuntimeError('App is unmarked or has a test entrypoint. Run again with --build to build lib/main.dart.')


def compile_swift(output, sources, *flags):
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    run('xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
        '-module-cache-path', str(BUILD / 'module-cache'), *flags,
        *map(str, sources), '-o', str(output))


def build_host():
    app = BUILD / 'HuahuoBleRelay.app'
    executable = app / 'Contents' / 'MacOS' / 'HuahuoBleRelay'
    executable.parent.mkdir(parents=True, exist_ok=True)
    info = {
        'CFBundleIdentifier': 'com.hangzhouchuda.huahuoai.ble-relay-dev',
        'CFBundleName': 'Huahuo BLE Relay (Development)',
        'CFBundleExecutable': 'HuahuoBleRelay',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'NSBluetoothAlwaysUsageDescription': 'Use this Mac’s Bluetooth to test a real recording card from the iOS Simulator.',
        'NSBluetoothPeripheralUsageDescription': 'Connect the recording card for simulator development testing.',
        'LSUIElement': True,
    }
    (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
    compile_swift(executable, [NATIVE / 'RecordingCardRelayWire.swift', HERE / 'main.swift'])
    run('codesign', '--force', '--sign', '-', str(app))
    return executable


def read_frame(stream):
    def exact(count):
        result = bytearray()
        while len(result) < count:
            chunk = stream.recv(count - len(result))
            if not chunk:
                raise RuntimeError('Relay closed the probe connection')
            result.extend(chunk)
        return result
    size = struct.unpack('!I', exact(4))[0]
    if not 0 < size <= 1_048_576:
        raise RuntimeError('Invalid relay frame')
    return json.loads(exact(size))


def probe(port, token):
    # Read-only: never connects, pairs, records, writes GATT or deletes a file.
    with socket.create_connection(('127.0.0.1', port), timeout=5) as stream:
        sequence = 0
        def send(operation, **fields):
            nonlocal sequence
            sequence += 1
            data = json.dumps(dict(v=1, seq=sequence, op=operation, **fields)).encode()
            stream.sendall(struct.pack('!I', len(data)) + data)
        send('hello', token=token)
        deadline = time.monotonic() + 30
        scan_end = None
        devices, candidates = set(), set()
        ping_at = time.monotonic()
        while time.monotonic() < deadline:
            if time.monotonic() - ping_at > 2:
                send('ping'); ping_at = time.monotonic()
            if not select.select([stream], [], [], 0.5)[0]:
                continue
            message = read_frame(stream)
            if message.get('event') == 'state':
                state = message.get('state')
                print(f'CoreBluetooth state={state} (5=poweredOn, 4=off, 3=unauthorized)', flush=True)
                if state == 5 and scan_end is None:
                    send('scan', uuids=[], duplicates=True)
                    scan_end = time.monotonic() + 6
                elif state in (2, 3, 4):
                    raise RuntimeError('Mac Bluetooth unavailable; resolve the reported system state and retry')
            if message.get('event') == 'discovered':
                identifier = message.get('peripheral')
                devices.add(identifier)
                data = base64.b64decode(message.get('manufacturer', ''))
                if data.startswith(bytes([0x5C, 0x37])) and len(data) > 8:
                    candidates.add(identifier)
            if scan_end is not None and time.monotonic() >= scan_end:
                send('stopScan')
                print(f'Read-only scan: {len(devices)} peripherals; {len(candidates)} FW920 manufacturer candidates.', flush=True)
                return
        raise RuntimeError('Bluetooth state did not become ready before probe deadline')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Booted simulator UUID for the already-built Debug app')
    parser.add_argument('--build', action='store_true', help='Build simulator Debug with FVM + Bundler first')
    parser.add_argument('--probe', action='store_true', help='Read-only Mac BLE scan; no simulator needed')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--integration-test', action='store_true', help='Read-only scan through the real simulator method channel')
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    if args.self_test:
        executable = BUILD / 'wire-tests'
        compile_swift(executable, [NATIVE / 'RecordingCardRelayWire.swift',
          NATIVE / 'RecordingCardSimulatorBluetooth.swift', HERE / 'WireTests.swift'],
          '-D', 'BLE_PROXY_TESTING', '-parse-as-library')
        run(str(executable))
        run('python3', str(HERE / 'LauncherTests.py'))
        return
    if not args.probe and not args.device:
        parser.error('Supply --device <booted-simulator-UUID> or --probe')
    if args.build and (not args.device or args.probe or args.integration_test):
        parser.error('--build requires --device and cannot be combined with probe/integration-test')
    if args.device:
        devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
        if not any(d['udid'] == args.device and d['state'] == 'Booted'
                   for rows in devices['devices'].values() for d in rows):
            parser.error('Select an existing booted simulator')
    if args.build:
        environment = dict(os.environ)
        for key in ('HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET', 'FLUTTER_TARGET', 'DART_DEFINES'):
            environment.pop(key, None)
        run('rbenv', 'exec', 'bundle', 'exec', 'fvm', 'flutter', 'build', 'ios',
            '--simulator', '--debug', '--config-only', '--no-pub', '--target=lib/main.dart',
            '--dart-define=HUAHUO_API_BASE_URL=https://chuda.cc', cwd=ROOT, env=environment)
        run('xcodebuild', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
            '-configuration', 'Debug', '-sdk', 'iphonesimulator',
            '-destination', f'platform=iOS Simulator,id={args.device}',
            f'CONFIGURATION_BUILD_DIR={ROOT / "build/ios/iphonesimulator"}',
            'build', '-quiet', cwd=ROOT, env=environment)
    if args.device:
        app = ROOT / 'build' / 'ios' / 'iphonesimulator' / 'Runner.app'
        if not args.integration_test:
            if not app.exists():
                parser.error('Build the Debug simulator app first or pass --build')
            require_formal_app(app)
            run('xcrun', 'simctl', 'install', args.device, str(app))
    executable = build_host()
    with tempfile.TemporaryDirectory(prefix='huahuo-ble-relay-') as temporary:
        token = secrets.token_hex(32)
        token_file, ready_file = Path(temporary) / 'token', Path(temporary) / 'ready'
        token_file.write_text(token); token_file.chmod(0o600)
        environment = dict(os.environ, HUAHUO_BLE_PROXY_TOKEN_FILE=str(token_file),
                           HUAHUO_BLE_PROXY_READY_FILE=str(ready_file))
        process = subprocess.Popen([str(executable)], env=environment)
        try:
            deadline = time.monotonic() + 10
            while not ready_file.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('BLE relay did not start')
                time.sleep(0.1)
            port = int(ready_file.read_text())
            if args.probe:
                probe(port, token)
                return
            if args.integration_test:
                environment = dict(os.environ, SIMCTL_CHILD_HUAHUO_BLE_PROXY_PORT=str(port),
                                   SIMCTL_CHILD_HUAHUO_BLE_PROXY_TOKEN=token,
                                   HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET='1')
                run('rbenv', 'exec', 'bundle', 'exec', 'fvm', 'flutter', 'test',
                    'integration_test/ble_relay_scan_test.dart', '-d', args.device,
                    '--dart-define=BLE_RELAY_HARDWARE_TEST=true', env=environment, cwd=ROOT,
                    timeout=300)
                return
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, BUNDLE],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            environment = dict(os.environ, SIMCTL_CHILD_HUAHUO_BLE_PROXY_PORT=str(port),
                               SIMCTL_CHILD_HUAHUO_BLE_PROXY_TOKEN=token)
            run('xcrun', 'simctl', 'launch', args.device, BUNDLE, env=environment)
            print('Relay active for this simulator launch. Ctrl-C stops the host; restart this command for a new session.', flush=True)
            process.wait()
        except KeyboardInterrupt:
            pass
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()


if __name__ == '__main__':
    main()
