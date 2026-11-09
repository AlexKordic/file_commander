"""Exercise app replacement with real signed bundles in disposable directories."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('install_app', ROOT / 'macos/tools/install_app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
run = subprocess.run


@unittest.skipUnless(sys.platform == 'darwin', 'macOS signed bundles and atomic rename')
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='fc-install-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / 'Installed Apps'
        self.old = self.bundle(self.directory / installer.APP_NAME, 'old')
        self.source = self.bundle(self.root / 'Build with spaces' / installer.APP_NAME, 'new')

    def bundle(self, app, version):
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': installer.BUNDLE_ID,
            'CFBundleExecutable': 'FileCommander',
            'CFBundlePackageType': 'APPL',
        }))
        (app / 'Contents/Resources' / f'{version}.txt').write_text(version)
        executable = app / 'Contents/MacOS/FileCommander'
        shutil.copyfile('/bin/echo', executable)
        executable.chmod(0o755)
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)],
            check=True, capture_output=True)
        return app

    def no_app_running(self, command, **kwargs):
        # Process discovery is controlled; copy, signing and rename are real.
        if command[0] == '/usr/bin/pgrep':
            return subprocess.CompletedProcess(command, 1, '', '')
        return run(command, **kwargs)

    def unchanged(self):
        self.assertTrue((self.old / 'Contents/Resources/old.txt').exists())
        self.assertFalse((self.old / 'Contents/Resources/new.txt').exists())
        self.assertEqual(list(self.directory.iterdir()), [self.old])
        installer.verify_signature(self.old)

    def test_replace_removes_old_resources_and_preserves_source(self):
        with mock.patch.object(installer.subprocess, 'run', side_effect=self.no_app_running):
            self.assertEqual(installer.install(self.source, self.directory), self.old)
        self.assertTrue((self.old / 'Contents/Resources/new.txt').exists())
        self.assertFalse((self.old / 'Contents/Resources/old.txt').exists())
        self.assertEqual(list(self.directory.iterdir()), [self.old])
        installer.verify_signature(self.old)
        installer.verify_signature(self.source)

    def test_first_install(self):
        directory = self.root / 'First install'
        with mock.patch.object(installer.subprocess, 'run', side_effect=self.no_app_running):
            destination = installer.install(self.source, directory)
        installer.verify_signature(destination)
        self.assertEqual(list(directory.iterdir()), [destination])

    def test_certificate_install_rejects_an_ad_hoc_replacement(self):
        def team(app):
            return 'TESTTEAM01' if app == self.old else None
        with mock.patch.object(installer, 'signature_team', side_effect=team), self.assertRaisesRegex(ValueError, 'expected team'):
            installer.install(self.source, self.directory)
        self.unchanged()

    def test_matching_team_replacement(self):
        with mock.patch.object(installer, 'signature_team', return_value='TESTTEAM01'), \
             mock.patch.object(installer.subprocess, 'run', side_effect=self.no_app_running):
            self.assertEqual(installer.install(self.source, self.directory, expected_team='TESTTEAM01'), self.old)
        self.assertTrue((self.old / 'Contents/Resources/new.txt').exists())

    def test_explicit_team_rejects_another_certificate(self):
        with mock.patch.object(installer, 'signature_team', return_value='TESTTEAM02'), \
             self.assertRaisesRegex(ValueError, 'expected team'):
            installer.install(self.source, self.directory, expected_team='TESTTEAM01')
        self.unchanged()

    def test_signing_team_changed_during_copy_preserves_install(self):
        def team(app):
            return 'TESTTEAM01' if app in (self.source, self.old) else 'TESTTEAM02'
        with mock.patch.object(installer, 'signature_team', side_effect=team), \
             mock.patch.object(installer.subprocess, 'run', side_effect=self.no_app_running), \
             self.assertRaisesRegex(ValueError, 'staged app signing team changed'):
            installer.install(self.source, self.directory, expected_team='TESTTEAM01')
        self.unchanged()

    def test_invalid_source_signature_preserves_install(self):
        (self.source / 'Contents/Resources/new.txt').write_text('tampered')
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source, self.directory)
        self.unchanged()

    def test_copy_failure_preserves_install(self):
        def fail_copy(command, **kwargs):
            if command[0] == '/usr/bin/ditto':
                raise subprocess.CalledProcessError(1, command)
            return self.no_app_running(command, **kwargs)
        with mock.patch.object(installer.subprocess, 'run', side_effect=fail_copy):
            with self.assertRaises(subprocess.CalledProcessError):
                installer.install(self.source, self.directory)
        self.unchanged()

    def test_corrupt_staged_copy_preserves_install(self):
        def corrupt_copy(command, **kwargs):
            result = self.no_app_running(command, **kwargs)
            if command[0] == '/usr/bin/ditto':
                (Path(command[-1]) / 'Contents/Resources/new.txt').write_text('bad copy')
            return result
        with mock.patch.object(installer.subprocess, 'run', side_effect=corrupt_copy):
            with self.assertRaises(subprocess.CalledProcessError):
                installer.install(self.source, self.directory)
        self.unchanged()

    def test_rename_failure_preserves_install(self):
        with mock.patch.object(installer.subprocess, 'run', side_effect=self.no_app_running):
            with mock.patch.object(installer, 'place_bundle', side_effect=OSError('rename denied')):
                with self.assertRaises(OSError):
                    installer.install(self.source, self.directory)
        self.unchanged()

    def test_exclusive_rename_does_not_clobber_a_concurrent_install(self):
        staged = self.root / 'Other bundle'
        shutil.copytree(self.source, staged)
        with mock.patch.object(Path, 'exists', return_value=False):
            with self.assertRaises(FileExistsError):
                installer.place_bundle(staged, self.old)
        self.unchanged()
        installer.verify_signature(staged)

    def test_running_app_preserves_install(self):
        with mock.patch.object(installer.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 0, '123\n', '')):
            with self.assertRaisesRegex(ValueError, 'Quit File Commander'):
                installer.install(self.source, self.directory)
        self.unchanged()

    def test_app_opened_during_copy_preserves_install(self):
        checks = iter([1, 0])
        def app_opens(command, **kwargs):
            if command[0] == '/usr/bin/pgrep':
                return subprocess.CompletedProcess(command, next(checks), '', '')
            return run(command, **kwargs)
        with mock.patch.object(installer.subprocess, 'run', side_effect=app_opens):
            with self.assertRaisesRegex(ValueError, 'Quit File Commander'):
                installer.install(self.source, self.directory)
        self.unchanged()

    def test_process_query_failure_preserves_install(self):
        with mock.patch.object(installer.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 2, '', 'process list unavailable')):
            with self.assertRaisesRegex(ValueError, 'Cannot check'):
                installer.install(self.source, self.directory)
        self.unchanged()

    def test_symlink_destination_is_refused(self):
        directory = self.root / 'Linked install'
        directory.mkdir()
        (directory / installer.APP_NAME).symlink_to(self.old, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            installer.install(self.source, directory)
        self.unchanged()


class BuildFailureTests(unittest.TestCase):
    def check_failure(self, failed_command):
        with tempfile.TemporaryDirectory(prefix='fc-build-failure-') as temporary:
            root = Path(temporary)
            (root / 'macos').mkdir()
            shutil.copy2(ROOT / 'macos/build_app.sh', root / 'macos/build_app.sh')
            (root / 'build-macos').mkdir()
            (root / 'build-macos/CMakeCache.txt').touch()
            (root / 'build-macos/libfc_engine_bundle.a').write_text('stale engine')
            directory = root / 'Installed apps'
            directory.mkdir()
            sentinel = directory / 'old-install.txt'
            sentinel.write_text('keep')
            commands = root / 'commands'
            commands.mkdir()
            trace = root / 'trace'
            for name in ['cmake', 'swift']:
                command = commands / name
                command.write_text('#!/bin/sh\n'
                                   'echo "${0##*/}" >> "$FC_TEST_BUILD_TRACE"\n'
                                   f'exit {37 if name == failed_command else 0}\n')
                command.chmod(0o755)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                       FC_TEST_BUILD_TRACE=str(trace), FC_APP_INSTALL_DIR=str(directory))
            result = run(['/bin/bash', str(root / 'macos/build_app.sh'), '--install'],
                         env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_text(), 'keep')
            self.assertEqual(list(directory.iterdir()), [sentinel])
            self.assertEqual(trace.read_text().splitlines(), ['cmake'] if failed_command == 'cmake' else ['cmake', 'swift'])

    def test_failed_engine_build_does_not_use_stale_library(self):
        self.check_failure('cmake')

    def test_failed_swift_build_stops_before_install(self):
        self.check_failure('swift')


class XcodeBuildFailureTests(unittest.TestCase):
    def check_failure(self, configuration):
        with tempfile.TemporaryDirectory(prefix='fc-xcode-build-') as temporary:
            root = Path(temporary)
            tools = root / 'macos/tools'
            tools.mkdir(parents=True)
            script = tools / 'xcode_build_app.sh'
            shutil.copy2(ROOT / 'macos/tools/xcode_build_app.sh', script)
            build = tools.parent / 'build_app.sh'
            build.write_text('#!/bin/bash\n'
                             'printf "%s\\n" "$FC_CODESIGN_IDENTITY" "$@" > "$FC_TEST_BUILD_TRACE"\n'
                             'exit 37\n')
            build.chmod(0o755)
            product = root / 'Xcode products/File Commander.app/Contents/MacOS/FileCommander'
            product.parent.mkdir(parents=True)
            product.write_text('previous build')
            trace = root / 'trace'
            env = dict(os.environ,
                       CONFIGURATION=configuration,
                       TARGET_BUILD_DIR=str(root / 'Xcode products'),
                       EXECUTABLE_FOLDER_PATH='File Commander.app/Contents/MacOS',
                       UNLOCALIZED_RESOURCES_FOLDER_PATH='File Commander.app/Contents/Resources',
                       WRAPPER_NAME='File Commander.app',
                       DERIVED_FILE_DIR=str(root / 'Derived'),
                       FC_CODESIGN_IDENTITY='inherited signing identity',
                       FC_TEST_BUILD_TRACE=str(trace))
            result = run(['/bin/bash', str(script)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
            self.assertEqual(product.read_text(), 'previous build')
            self.assertEqual(trace.read_text().splitlines(), ['-', '--debug'] if configuration == 'Debug' else ['-'])

    def test_failed_debug_build_preserves_previous_xcode_product(self):
        self.check_failure('Debug')

    def test_failed_release_build_preserves_previous_xcode_product(self):
        self.check_failure('Release')


if __name__ == '__main__':
    unittest.main()
