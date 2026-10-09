#!/usr/bin/env python3
"""Create isolated pinned checkouts; never reset or edit existing input trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def provision_lzma(repo, spec, target, source=None):
    if target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    # Stage first so rejection or interruption does not leave a partial input.
    with tempfile.TemporaryDirectory(prefix='fc-sdk-', dir=target.parent) as directory:
        staged = Path(directory) / 'source'
        if source:
            shutil.copytree(source, staged, ignore=shutil.ignore_patterns('_o', '_o_*', '.git'))
        else:
            archive = repo / spec['archive']
            if hashlib.sha256(archive.read_bytes()).hexdigest() != spec['archive_sha256']:
                raise ValueError('lzma: dependency archive fingerprint mismatch')
            with tarfile.open(archive, 'r:gz') as package:
                if any(not member.isfile() and not member.isdir() for member in package.getmembers()):
                    raise ValueError('lzma: source archive must contain only files and directories')
                package.extractall(staged, filter='data')
        staged.rename(target)


def main():
    repo = Path(__file__).resolve().parent.parent
    manifest = json.loads((repo / 'dependencies.json').read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--ftxui-url', default=os.getenv('FC_FTXUI_MIRROR'))
    parser.add_argument('--fresh-url', default=os.getenv('FC_FRESH_MIRROR'))
    parser.add_argument('--lzma-source', type=Path, help='Optional SDK 26.00 folder; default is the bundled source snapshot')
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name, spec in manifest['git'].items():
        target = root / name
        paths[name] = target
        if target.exists():
            continue
        source = args.ftxui_url if name == 'ftxui' and args.ftxui_url else spec['source']
        if name == 'fresh' and args.fresh_url:
            source = args.fresh_url
        bundle = repo / spec['bundle'] if 'bundle' in spec else None
        if bundle and hashlib.sha256(bundle.read_bytes()).hexdigest() != spec['bundle_sha256']:
            raise ValueError(f'{name}: dependency bundle fingerprint mismatch')
        subprocess.run(['git', 'clone', '--no-checkout', source, str(target)], check=True, timeout=600)
        if bundle:
            subprocess.run(['git', '-C', str(target), 'bundle', 'verify', str(bundle)], check=True, timeout=60)
            subprocess.run(['git', '-C', str(target), 'fetch', str(bundle), 'refs/heads/fc-editor-workflow'], check=True, timeout=60)
        subprocess.run(['git', '-C', str(target), 'checkout', '--detach', spec['revision']], check=True, timeout=60)
    sdk = root / 'lzma'
    provision_lzma(repo, manifest['lzma'], sdk, args.lzma_source)
    command = [sys.executable, str(repo / 'tools/check_dependencies.py'), '--lzma', str(sdk)]
    for name, path in paths.items():
        command += ['--' + name, str(path)]
    subprocess.run(command, check=True, timeout=60)
    print('Pinned dependency root:', root)


if __name__ == '__main__':
    main()
