import base64
import json
from pathlib import Path
import tempfile
import unittest

from scripts import sparkle_dependency as sparkle


class SparkleDependencyTests(unittest.TestCase):
    def test_unconfigured_build_has_no_feed_and_configured_build_requires_signed_explicit_updates(self):
        self.assertEqual(sparkle.update_settings(None), {})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'public-update-config.json'
            config = {'feedURL': 'https://updates.example.test/mac/appcast.xml',
                      'publicEDKey': base64.b64encode(b'0123456789abcdef' * 2).decode()}
            path.write_text(json.dumps(config))
            settings = sparkle.update_settings(path)
            self.assertTrue(settings['SURequireSignedFeed'])
            self.assertTrue(settings['SUVerifyUpdateBeforeExtraction'])
            self.assertFalse(settings['SUAllowsAutomaticUpdates'])
            self.assertFalse(settings['SUAutomaticallyUpdate'])
            self.assertEqual(settings['SUSignedFeedFailureExpirationInterval'], 0)
            for change in ({'feedURL': 'http://updates.example.test/feed'},
                           {'feedURL': 'https://user:secret@updates.example.test/feed'},
                           {'feedURL': 'https://updates.example.test/feed?token=secret'},
                           {'publicEDKey': 'invalid'}, {'privateKey': 'never-read-this'}):
                path.write_text(json.dumps(config | change))
                with self.assertRaises(ValueError):
                    sparkle.update_settings(path)

    def test_tampered_dependency_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            archive = scratch / 'sparkle.tar.xz'
            archive.write_bytes(b'not the official framework')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                sparkle.framework(archive, scratch)
            self.assertFalse((scratch / 'sparkle').exists())

    def test_nested_signing_uses_inside_out_order(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Paceman.app'
            framework = app / 'Contents/Frameworks/Sparkle.framework'
            framework.mkdir(parents=True)
            calls = []
            sparkle.sign_nested(app, lambda *args: calls.append(args), ['--sign', 'fixture'])
            self.assertEqual(calls[-1][-1], framework)
            self.assertEqual(len(calls), 5)
            self.assertTrue(str(calls[0][-1]).endswith('Downloader.xpc'))
