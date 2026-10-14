import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location('release_check', pathlib.Path(__file__).parents[1] / 'Tools/release-check.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_hardened_runtime_and_injection_exceptions(self):
        output = ('CodeDirectory v=20500 size=100 flags=0x10002(adhoc,runtime)\n'
                  'Signature=adhoc\nCDHash=0123456789012345678901234567890123456789\n')
        self.assertTrue(release.validate_signature_metadata(output, {})['hardenedRuntime'])
        for malformed in (output.replace('0x10002', '0x2'), output.replace('CodeDirectory', 'Unknown')):
            with self.assertRaises(ValueError):
                release.validate_signature_metadata(malformed, {})
        for key in release.FORBIDDEN_ENTITLEMENTS:
            for value in (True, 1, 0, 'false', [], {}):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    release.validate_signature_metadata(output, {key: value})
            release.validate_signature_metadata(output, {key: False})
        with self.assertRaises(ValueError):
            release.validate_signature_metadata(output, [])

    def test_notarization_requires_successful_stapler_validation(self):
        with mock.patch.object(release.subprocess, 'run', return_value=mock.Mock(returncode=0)):
            self.assertEqual(release.notarization('app'), 'stapled-valid')
        with mock.patch.object(release.subprocess, 'run', return_value=mock.Mock(returncode=65)):
            self.assertEqual(release.notarization('app'), 'not-verified')
        for failure in (FileNotFoundError(), release.subprocess.TimeoutExpired('stapler', 60)):
            with mock.patch.object(release.subprocess, 'run', side_effect=failure):
                self.assertEqual(release.notarization('app'), 'not-verified')

    def test_version_tag_and_minimum(self):
        with tempfile.TemporaryDirectory() as folder:
            plist = pathlib.Path(folder) / 'Info.plist'
            plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3', 'LSMinimumSystemVersion': '14.0'}))
            self.assertEqual(release.version_from_plist(plist, 'v1.2.3'), '1.2.3')
            for tag in ('v1.2.4', '1.2.3', 'v1.2.3-beta'):
                with self.assertRaises(ValueError):
                    release.version_from_plist(plist, tag)
            plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3', 'LSMinimumSystemVersion': '13.0'}))
            with self.assertRaises(ValueError):
                release.version_from_plist(plist)

    def test_zip_exactness_and_private_file_rejection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            app = root / 'StateLite.app'
            (app / 'Contents').mkdir(parents=True)
            source = app / 'Contents/test'
            source.write_bytes(b'app bytes')
            archive = root / 'release.zip'
            with zipfile.ZipFile(archive, 'w') as output:
                output.write(source, 'StateLite.app/Contents/test')
            release.validate_zip(archive, app)
            for extra in ('private-notes.txt', '../escape', '/absolute'):
                with zipfile.ZipFile(archive, 'w') as output:
                    output.write(source, 'StateLite.app/Contents/test')
                    output.writestr(extra, 'not allowed')
                with self.assertRaises(ValueError):
                    release.validate_zip(archive, app)
            with zipfile.ZipFile(archive, 'w') as output:
                output.writestr('StateLite.app/Contents/test', 'modified after signing')
            with self.assertRaises(ValueError):
                release.validate_zip(archive, app)


if __name__ == '__main__':
    unittest.main()
