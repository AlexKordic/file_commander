#!/usr/bin/env python3
"""Writes test archives of a folder, so the archive tests need no fixture binaries: Python's standard library writes the common formats, and a libarchive tar, when there is one, the rest.

    make_archives.py SOURCE_DIR OUTPUT_DIR

OUTPUT_DIR receives tree.zip, tree.tar, tree.tar.gz, tree.tar.bz2, tree.tar.xz, hostile.tar.gz (entries that try to leave the destination), and one.txt.gz (the first regular file of SOURCE_DIR, gzip-compressed, with its name in the gzip header). Entries are sorted and timestamps fixed, so the bytes are the same on every run.

When a libarchive tar (bsdtar; macOS's /usr/bin/tar is one) is on hand, it also writes tree.cpio, tree.iso, tree.xar, tree.bsd.7z and tree.tar.zst, for the formats Python can't write. Their names are printed, one per line, so a test knows which exist.
"""
import gzip
import io
import os
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

MTIME = 1_700_000_000


def entries(root):
    for path in sorted(root.rglob('*')):
        yield path, path.relative_to(root).as_posix()


def main():
    source, output = Path(sys.argv[1]), Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output / 'tree.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, name in entries(source):
            info = zipfile.ZipInfo(name + ('/' if path.is_dir() else ''), date_time=(2023, 11, 14, 22, 13, 20))
            info.external_attr = ((0o40755 if path.is_dir() else 0o100644) << 16)
            archive.writestr(info, b'' if path.is_dir() else path.read_bytes(), zipfile.ZIP_DEFLATED)
    for suffix, mode in (('tar', 'w'), ('tar.gz', 'w:gz'), ('tar.bz2', 'w:bz2'), ('tar.xz', 'w:xz')):
        with tarfile.open(output / f'tree.{suffix}', mode, format=tarfile.PAX_FORMAT) as archive:
            for path, name in entries(source):
                info = archive.gettarinfo(str(path), name)
                info.mtime, info.uid, info.gid, info.uname, info.gname = MTIME, 0, 0, '', ''
                if path.is_file():
                    with open(path, 'rb') as data:
                        archive.addfile(info, data)
                else:
                    archive.addfile(info)
    bsdtar = next((c for c in (shutil.which('bsdtar'), '/usr/bin/tar') if c and os.access(c, os.X_OK) and
                   'bsdtar' in subprocess.run([c, '--version'], capture_output=True, text=True).stdout), None)
    if bsdtar:
        for name, args in (('tree.cpio', ['--format', 'newc']), ('tree.iso', ['--format', 'iso9660']), ('tree.xar', ['--format', 'xar']),
                           ('tree.bsd.7z', ['--format', '7zip']), ('tree.tar.zst', ['--format', 'pax', '--zstd'])):
            made = subprocess.run([bsdtar, *args, '-cf', str(output / name), '-C', str(source), '.'], capture_output=True)
            if made.returncode == 0:
                print(name)
            else:
                (output / name).unlink(missing_ok=True)
    # Entries an extractor must not follow out of its destination: a link inside it (kept), a link out of it, a "../" path and an absolute one.
    with tarfile.open(output / 'hostile.tar.gz', 'w:gz', format=tarfile.PAX_FORMAT) as archive:
        def add(name, data=None, link=None):
            info = tarfile.TarInfo(name)
            info.mtime = MTIME
            if link is not None:
                info.type, info.linkname = tarfile.SYMTYPE, link
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        add('ok.txt', b'kept')
        add('docs/inner', link='../ok.txt')
        add('up', link='../../outside')
        add('../evil.txt', b'escaped')
        add('/abs.txt', b'absolute')
    first = next(path for path, _ in entries(source) if path.is_file())
    with open(output / 'one.txt.gz', 'wb') as raw:
        with gzip.GzipFile(filename=first.name, mode='wb', fileobj=raw, mtime=MTIME) as archive:
            archive.write(first.read_bytes())


if __name__ == '__main__':
    main()
