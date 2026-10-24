"""Exercise the release verifier against synthetic mounted bundles, without mounting a DMG."""
from contextlib import nullcontext
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_desktop_release',
    Path(__file__).resolve().parents[1] / 'scripts/prepare-desktop-release.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class MacReleaseVerificationTests(unittest.TestCase):
    def verify(self, *, universal, sparkle_last):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'mount/Paceman.app'
            native = app / 'Contents/MacOS/Paceman'
            sparkle = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
            revision = 'a' * 40
            runtime = {'version': '3.14.fixture', 'sha256': 'b' * 64}

            def run(*args):
                if args[:2] == ('/usr/bin/hdiutil', 'attach'):
                    for binary in (native, sparkle):
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
                    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                        'CFBundleIdentifier': 'ai.paceman.macos', 'CFBundleShortVersionString': '0.4.1',
                        'CFBundleVersion': '31', 'LSMinimumSystemVersion': '15.0', 'LSUIElement': True}))
                    library = app / 'Contents/Resources/lib'
                    library.mkdir(parents=True)
                    (library / 'build-info.json').write_text(json.dumps({
                        'sourceRevision': revision, 'release': '0.4.1-alpha.1',
                        'pythonVersion': runtime['version'], 'pythonArchiveSHA256': runtime['sha256']}))

            def output(args, **_):
                if args[0] == '/usr/bin/lipo':
                    return 'x86_64 arm64' if Path(args[-1]) == universal(native, sparkle) else 'arm64'
                if args[0] == '/usr/bin/vtool':
                    return 'platform MACOS\nminos 12.0\n'
                raise AssertionError(args)

            order = [native, sparkle] if sparkle_last else [sparkle, native]
            with patch.object(prepare.tempfile, 'TemporaryDirectory', return_value=nullcontext(str(root))), \
                 patch.object(prepare, 'run', side_effect=run) as commands, \
                 patch.object(prepare.subprocess, 'check_output', side_effect=output), \
                 patch.object(Path, 'rglob', return_value=iter(order)):
                prepare.verify_mac(root / 'fixture.dmg', revision, '0.4.1-alpha.1', 31, runtime)
                self.assertIn(('/usr/bin/codesign', '--verify', '--deep', '--strict', app),
                              [call.args for call in commands.call_args_list])

    def test_official_universal_sparkle_is_accepted_regardless_of_final_directory_entry(self):
        for last in (False, True):
            with self.subTest(sparkle_last=last):
                self.verify(universal=lambda _native, sparkle: sparkle, sparkle_last=last)

    def test_universal_non_sparkle_binary_is_rejected_regardless_of_final_directory_entry(self):
        for last in (False, True):
            with self.subTest(sparkle_last=last):
                with self.assertRaisesRegex(ValueError, 'Unexpected Paceman architectures'):
                    self.verify(universal=lambda native, _sparkle: native, sparkle_last=last)
