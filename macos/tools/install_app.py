#!/usr/bin/env python3
"""Verify and install a built File Commander.app without merging app bundles."""
import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


APP_NAME = 'File Commander.app'
BUNDLE_ID = 'me.h264.filecommander'


def default_directory():
    user_apps = Path.home() / 'Applications'
    system_apps = Path('/Applications')
    if (user_apps / APP_NAME).exists():
        return user_apps
    if (system_apps / APP_NAME).exists():
        return system_apps
    return user_apps


def check_bundle(app):
    if app.is_symlink():
        raise ValueError(f'Refusing to replace or copy a symlink: {app}')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError(f'Not a File Commander app bundle: {app}')


def verify_signature(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def signature_team(app):
    result = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)],
                            capture_output=True, text=True, check=True)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', result.stderr, re.MULTILINE)
    return match.group(1) if match else None


def check_not_running():
    result = subprocess.run(
        ['/usr/bin/pgrep', '-u', str(os.getuid()), '-x', 'FileCommander'],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        raise ValueError('Quit File Commander before installing, then retry --install.')
    if result.returncode != 1:
        raise ValueError('Cannot check whether File Commander is running: ' + result.stderr.strip())


def place_bundle(staged, destination):
    # Both paths are on the destination volume. Darwin swaps existing bundles
    # atomically; a first install uses exclusive rename to avoid overwriting a
    # destination created while the copy was being prepared.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = 0x00000002 if destination.exists() else 0x00000004  # RENAME_SWAP / RENAME_EXCL
    if rename(os.fsencode(staged), os.fsencode(destination), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install(app, directory, expected_team=None):
    if sys.platform != 'darwin':
        raise ValueError('Installing the macOS app requires macOS.')
    check_bundle(app)
    app = app.resolve(strict=True)
    directory = directory.expanduser().resolve()
    destination = directory / APP_NAME
    if destination == app:
        raise ValueError('The install directory must differ from the build directory.')
    if destination.exists() or destination.is_symlink():
        check_bundle(destination)

    verify_signature(app)
    source_team = signature_team(app)
    destination_team = signature_team(destination) if destination.exists() else None
    required_team = expected_team or destination_team
    if required_team and source_team != required_team:
        raise ValueError('The new app must be signed by the expected team; refusing a signing identity change.')
    if expected_team and destination_team and destination_team != expected_team:
        raise ValueError('The installed app belongs to another team; refusing to replace it.')
    check_not_running()
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.fc-install-', dir=directory,
                                     ignore_cleanup_errors=True) as temporary:
        staged = Path(temporary) / APP_NAME
        subprocess.run(['/usr/bin/ditto', str(app), str(staged)], check=True)
        verify_signature(staged)
        if signature_team(staged) != source_team:
            raise ValueError('The staged app signing team changed during preparation; retry installation.')
        # Recheck after copying: a user may have opened or replaced the app
        # while the staged copy was being prepared.
        check_not_running()
        if destination.exists() or destination.is_symlink():
            check_bundle(destination)
            if signature_team(destination) != destination_team:
                raise ValueError('The installed signing identity changed during preparation; retry installation.')
        place_bundle(staged, destination)
        # After a swap the old bundle is at staged, inside our temporary dir.
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--directory', type=Path,
                        default=os.environ.get('FC_APP_INSTALL_DIR') or None)
    parser.add_argument('--expected-team', help='Require a signing team; never stored in the repository.')
    args = parser.parse_args()
    try:
        destination = install(args.app, args.directory if args.directory is not None else default_directory(), args.expected_team)
    except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f'install_app: {error}', file=sys.stderr)
        return 1
    print(f'install_app: installed {destination}', file=sys.stderr)
    print(destination)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
