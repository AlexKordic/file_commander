#!/usr/bin/env python3
"""Bundle absolute non-system dylib dependencies before signing a macOS app."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile


MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def macho(path):
    if not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MAGIC


def dependencies(path):
    text = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
    return {line.strip().split(' (compatibility version ', 1)[0]
            for line in text.splitlines() if line.startswith('\t')}


def minimum_macos(path):
    text = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
    versions = re.findall(r'^\s+minos ([0-9.]+)$', text, re.MULTILINE)
    versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', text)
    return max((tuple(map(int, version.split('.'))) for version in versions), default=(0,))


def patch(path, arguments):
    # Replacing a file preserves an editor that still maps its previous inode.
    descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        shutil.copyfile(path, temporary)
        temporary.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)
        subprocess.run(['/usr/bin/install_name_tool', *arguments, str(temporary)], check=True)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def bundle(app):
    contents = app / 'Contents'
    executables = contents / 'MacOS'
    frameworks = contents / 'Frameworks'
    if not executables.is_dir():
        raise ValueError('Expected a macOS app bundle with Contents/MacOS')
    roots = [path for folder in (executables, frameworks) if folder.exists()
             for path in sorted(folder.iterdir()) if macho(path)]
    pending = [(path, path) for path in roots]
    origins = {}
    while pending:
        target, original = pending.pop(0)
        changes = []
        for dependency in sorted(dependencies(original)):
            if not dependency.startswith('/') or dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            source = Path(dependency).resolve(strict=True)
            if source == original.resolve():
                continue  # A dylib's own LC_ID_DYLIB is also in otool -L.
            if source.suffix != '.dylib' or not macho(source):
                raise ValueError('Unsupported external native dependency: ' + dependency)
            name = source.name
            if name in origins and origins[name] != source:
                raise ValueError('Different native libraries share a bundle name: ' + name)
            destination = frameworks / name
            if name not in origins:
                origins[name] = source
                frameworks.mkdir(parents=True, exist_ok=True)
                if destination.resolve() != source:
                    descriptor, temporary = tempfile.mkstemp(prefix='.' + name + '-', dir=frameworks)
                    os.close(descriptor)
                    try:
                        shutil.copyfile(source, temporary)
                        os.chmod(temporary, 0o755)
                        os.replace(temporary, destination)
                    finally:
                        Path(temporary).unlink(missing_ok=True)
                patch(destination, ['-id', '@rpath/' + name])
                pending.append((destination, source))
                notices = contents / 'Resources/licenses/native-libraries' / name
                for pattern in ('COPYING*', 'LICENSE*', 'COPYRIGHT*', 'AUTHORS'):
                    for notice in source.parent.parent.glob(pattern):
                        if notice.is_file():
                            notices.mkdir(parents=True, exist_ok=True)
                            shutil.copyfile(notice, notices / notice.name)
            relative = os.path.relpath(destination, target.parent)
            changes += ['-change', dependency, '@loader_path/' + relative]
        if changes:
            patch(target, changes)
    copied = sorted(path.name for path in frameworks.iterdir() if macho(path)) if frameworks.exists() else []
    inventory = contents / 'Resources/native-libraries.json'
    inventory.parent.mkdir(parents=True, exist_ok=True)
    inventory.write_text(json.dumps(copied, indent=2) + '\n')
    info_path = contents / 'Info.plist'
    if info_path.exists():
        info = plistlib.loads(info_path.read_bytes())
        existing = tuple(map(int, info.get('LSMinimumSystemVersion', '0').split('.')))
        packaged = roots + [frameworks / name for name in copied]
        minimum = max([existing] + [minimum_macos(path) for path in packaged])
        info['LSMinimumSystemVersion'] = '.'.join(map(str, minimum))
        info_path.write_bytes(plistlib.dumps(info))
    return copied


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        copied = bundle(args.app)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'bundle_dylibs: ' + str(error) + '\n')
    print('Bundled native libraries: ' + (', '.join(copied) or 'none'))
