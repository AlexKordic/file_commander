"""R34: implementation timestamps trigger dependency rebuilds; restore timestamps.

Uses the source directories configured in build/CMakeCache.txt. Source contents
are never edited. Run after the normal build has populated dependency outputs.
"""
from pathlib import Path
import os
import subprocess
import time
import sys

repo = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / 'build'
cache = {}
for line in (build / 'CMakeCache.txt').read_text().splitlines():
    if ':' in line and '=' in line and not line.startswith(('#', '//')):
        key, value = line.split('=', 1)
        cache[key.split(':')[0]] = value
logs = build / 'review-dependencies'
logs.mkdir(exist_ok=True)


def rebuild(name, source, target, marker, output):
    original = source.stat()
    previous_output = output.stat().st_mtime_ns if output.exists() else 0
    try:
        os.utime(source, None)
        result = subprocess.run(['cmake', '--build', str(build), '--target', target, '-j10'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (logs / (name + '.log')).write_text(result.stdout)
        assert result.returncode == 0 and marker in result.stdout, f'{name}: rebuild missing/failed; see {logs}'
        assert output.stat().st_mtime_ns > previous_output, f'{name}: implementation object/output was not rebuilt'
    finally:
        os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
    print('PASS source dependency:', name, flush=True)


lua = Path(cache['FC_LUAJIT_SOURCE_DIR'])
original_object = lua / 'src/lj_api.o'
original_time = original_object.stat().st_mtime_ns if original_object.exists() else None
rebuild('LuaJIT', lua / 'src/lj_api.c', 'luajit_lib', 'CC        lj_api.o', build / 'third_party/luajit/source/src/lj_api.o')
assert (original_object.stat().st_mtime_ns if original_object.exists() else None) == original_time, 'LuaJIT wrote into shared source tree'
rebuild('7zr', Path(cache['FC_LZMA_SOURCE_DIR']) / 'C/Alloc.c', 'lzma_7zr', 'Alloc.c', build / 'third_party/lzma/_o/Alloc.o')
if cache.get('FC_BUILD_FRESH') == 'ON':
    fresh = Path(cache['FC_FRESH_SOURCE_DIR'])
    rebuild('Fresh', fresh / 'crates/fresh-core/src/lib.rs', 'fresh_bin', 'Compiling fresh-core', fresh / 'target/release/fresh')
