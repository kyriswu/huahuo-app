"""Regression gates for release/test artifact separation. No radio access."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from run import ROOT, require_formal_app


class EntrypointTests(unittest.TestCase):
    def guard(self, target='lib/main.dart', configuration='Debug', action='build', opt_in='0', define=''):
        environment = dict(os.environ, SRCROOT=str(ROOT / 'ios'),
                           FLUTTER_APPLICATION_PATH=str(ROOT), FLUTTER_TARGET=target,
                           CONFIGURATION=configuration, ACTION=action,
                           HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=opt_in,
                           DART_DEFINES=base64.b64encode(define.encode()).decode() if define else '')
        return subprocess.run(['/bin/sh', str(ROOT / 'tool' / 'ios_entrypoint_guard.sh')],
                              env=environment, capture_output=True).returncode

    def test_formal_builds(self):
        for config in ('Debug', 'Profile', 'Release'):
            self.assertEqual(self.guard(configuration=config), 0)
            self.assertEqual(self.guard(str(ROOT / 'lib/main.dart'), config), 0)

    def test_explicit_debug_test_only(self):
        target = 'integration_test/ble_relay_scan_test.dart'
        self.assertEqual(self.guard(target, opt_in='1'), 0)
        self.assertNotEqual(self.guard(target), 0)
        for config in ('Release', 'Profile'):
            self.assertNotEqual(self.guard(target, config, opt_in='1'), 0)
        for action in ('archive', 'install'):
            self.assertNotEqual(self.guard(target, action=action, opt_in='1'), 0)

    def test_formal_define_contamination(self):
        for define in ('BLE_RELAY_HARDWARE_TEST=true', 'HUAHUO_V3_DEMO_AUTH=true', 'HUAHUO_BOOT_PROBE=true'):
            self.assertNotEqual(self.guard(configuration='Release', opt_in='1', define=define), 0)
            self.assertNotEqual(self.guard(define=define), 0)
        self.assertEqual(self.guard(configuration='Release', define='HUAHUO_API_BASE_URL=https://chuda.cc'), 0)

    def test_built_artifact_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            for target in ('', 'integration_test/ble_relay_scan_test.dart', 'lib/main.dart', str(ROOT / 'lib/main.dart')):
                (app / 'Info.plist').write_bytes(plistlib.dumps({'HuahuoFlutterEntrypoint': target}))
                if target.endswith('/main.dart'):
                    require_formal_app(app)
                else:
                    with self.assertRaises(RuntimeError):
                        require_formal_app(app)


if __name__ == '__main__':
    unittest.main()
