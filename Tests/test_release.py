"""Release orchestration checks without certificates, builds, or Apple requests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['RELEASE_LOG'], 'a') as log:
    log.write(json.dumps([name] + args) + '\n')
if name == os.environ.get('FAIL_COMMAND'):
    sys.exit(1)
if name == 'xcrun' and args[:2] == ['notarytool', 'submit']:
    print(plistlib.dumps({'status': os.environ.get('NOTARY_STATUS', 'Accepted'),
                         'id': 'test-submission'}).decode())
elif name == 'ditto':
    target = pathlib.Path(args[-1])
    if '-c' in args:
        target.touch()
    else:
        target.mkdir()
elif name == 'hdiutil':
    pathlib.Path(args[-1]).touch()
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='barttery-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy(ROOT / 'scripts/release.sh', self.root / 'scripts')
        shutil.copy(ROOT / 'Info.plist', self.root)
        import plistlib
        with (self.root / 'Info.plist').open('rb') as source:
            version = plistlib.load(source)['CFBundleShortVersionString']
        self.dmg = self.root / f'Barttery-{version}.dmg'
        self.dmg.write_text('previous release')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('make', 'codesign', 'xcrun', 'spctl', 'ditto', 'hdiutil'):
            command = self.bin / name
            command.write_text(MOCK)
            command.chmod(0o755)
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        SIGN='Developer ID Application: Test (ABCDEFGHIJ)',
                        NOTARY_PROFILE='test-profile', RELEASE_LOG=str(self.log),
                        MAKE=str(self.bin / 'make'), TMPDIR=str(self.root))

    def run_release(self, **overrides):
        return subprocess.run(['bash', 'scripts/release.sh'], cwd=self.root,
                              env=dict(self.env, **overrides), capture_output=True,
                              text=True)

    def commands(self):
        import json
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_rejects_development_identity_before_any_work(self):
        result = self.run_release(SIGN='Apple Development: Test')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_requires_notary_profile(self):
        result = self.run_release(NOTARY_PROFILE='')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_successful_signed_and_notarized_release(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        build = next(command for command in commands if command[0] == 'make')
        self.assertIn('SIGN_FLAGS=--options runtime --timestamp', build)
        submissions = [c for c in commands if c[1:3] == ['notarytool', 'submit']]
        self.assertEqual(len(submissions), 2)
        self.assertTrue(submissions[0][3].endswith('.zip'))
        self.assertTrue(submissions[1][3].endswith('.dmg'))
        self.assertEqual(sum(c[1:3] == ['stapler', 'validate'] for c in commands), 2)
        self.assertFalse(any('--sign' in c and '-' in c for c in commands))
        self.assertEqual(self.dmg.read_bytes(), b'')
        self.assertEqual(list(self.root.glob('barttery-release.*')), [])

    def test_failures_preserve_previous_release(self):
        for overrides in ({'FAIL_COMMAND': 'codesign'},
                          {'NOTARY_STATUS': 'Invalid'},
                          {'FAIL_COMMAND': 'spctl'},
                          {'FAIL_COMMAND': 'hdiutil'}):
            with self.subTest(overrides=overrides):
                result = self.run_release(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.dmg.read_text(), 'previous release')
                self.assertEqual(list(self.root.glob('barttery-release.*')), [])


if __name__ == '__main__':
    unittest.main()
