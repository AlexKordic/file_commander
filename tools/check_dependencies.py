#!/usr/bin/env python3
"""Validate the repository's declared dependency inputs without changing checkouts."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parent.parent
manifest = json.loads((repo / 'dependencies.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
for name, value in manifest['git'].items():
    parser.add_argument('--' + name, type=Path, default=repo / value['default_path'])
parser.add_argument('--lzma', type=Path, default=repo / manifest['lzma']['default_path'])
parser.add_argument('--skip-fresh', action='store_true')
parser.add_argument('--skip-lzma', action='store_true')
args = parser.parse_args()
failures = []
for name, spec in manifest['git'].items():
    if name == 'fresh' and args.skip_fresh:
        continue
    path = getattr(args, name)
    try:
        revision = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True, stderr=subprocess.PIPE).strip()
        dirty = subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
        if revision != spec['revision'] or dirty:
            failures.append(f'{name}: expected clean {spec["revision"]}; found {revision}' + (' with modified tracked files' if dirty else ''))
    except (OSError, subprocess.CalledProcessError):
        failures.append(f'{name}: cannot read checkout at {path}')
if not args.skip_lzma:
    root = args.lzma
    paths = sorted(p for p in root.rglob('*') if p.is_file() and '_o' not in p.parts and
                   (p.suffix in ('.c', '.h', '.cpp', '.mak', '.S', '.asm') or p.name.startswith('makefile')))
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.relative_to(root).as_posix().encode() + b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    if len(paths) != manifest['lzma']['source_files'] or digest.hexdigest() != manifest['lzma']['source_sha256']:
        failures.append(f'lzma: source set differs from SDK {manifest["lzma"]["version"]} manifest')
if failures:
    raise SystemExit('\n'.join(failures))
print('Dependency revisions and source fingerprints match dependencies.json')
