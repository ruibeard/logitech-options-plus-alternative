#!/usr/bin/env python3
"""Installer regressions without modifying Applications or launching apps."""
import pathlib
import shutil
import tempfile
import unittest
import sys
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import build


class InstallTests(unittest.TestCase):
    def test_clean_replacement_and_failed_verification_preserve_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, destination = root / 'new.app', root / 'installed.app'
            source.mkdir()
            destination.mkdir()
            (source / 'current').write_text('new')
            (destination / 'obsolete').write_text('old')

            def run(command, *arguments, **kwargs):
                if command == 'ditto':
                    shutil.copytree(arguments[0], arguments[1])

            with patch.object(build, 'run', side_effect=run), patch.object(build, 'require_apps_stopped'):
                build.install_app(source, destination)
            self.assertFalse((destination / 'obsolete').exists())
            self.assertEqual((destination / 'current').read_text(), 'new')

            def reject_signature(command, *arguments, **kwargs):
                if command == 'codesign':
                    raise RuntimeError('invalid signature')
                run(command, *arguments, **kwargs)

            with patch.object(build, 'run', side_effect=reject_signature), patch.object(build, 'require_apps_stopped'):
                with self.assertRaises(RuntimeError):
                    build.install_app(source, destination)
            self.assertEqual((destination / 'current').read_text(), 'new')
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['installed.app', 'new.app'])

    def test_failed_replacement_restores_previous_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, destination = root / 'new.app', root / 'installed.app'
            source.mkdir()
            destination.mkdir()
            (destination / 'original').write_text('preserved')
            original_rename = pathlib.Path.rename

            def rename(path, target):
                if path.parent.name.startswith('.mxmouse-install-') and path.name == destination.name:
                    raise OSError('replacement failed')
                return original_rename(path, target)

            def run(command, *arguments, **kwargs):
                if command == 'ditto':
                    shutil.copytree(arguments[0], arguments[1])

            with patch.object(build, 'run', side_effect=run), patch.object(build, 'require_apps_stopped'), patch.object(pathlib.Path, 'rename', rename):
                with self.assertRaises(OSError):
                    build.install_app(source, destination)
            self.assertEqual((destination / 'original').read_text(), 'preserved')


if __name__ == '__main__':
    unittest.main()
