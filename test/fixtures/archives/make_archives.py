#!/usr/bin/env python3
"""Writes test archives of a folder with Python's standard library only, so the archive tests need no fixture binaries and no archiver but the one under test.

    make_archives.py SOURCE_DIR OUTPUT_DIR

OUTPUT_DIR receives tree.zip, tree.tar, tree.tar.gz, tree.tar.bz2, tree.tar.xz, and one.txt.gz (the first regular file of SOURCE_DIR, gzip-compressed, with its name in the gzip header). Entries are sorted and timestamps fixed, so the bytes are the same on every run.
"""
import gzip
import os
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
    first = next(path for path, _ in entries(source) if path.is_file())
    with open(output / 'one.txt.gz', 'wb') as raw:
        with gzip.GzipFile(filename=first.name, mode='wb', fileobj=raw, mtime=MTIME) as archive:
            archive.write(first.read_bytes())


if __name__ == '__main__':
    main()
