"""Validate built package bytes and run relocation; --build-only explicitly builds."""
from pathlib import Path
import argparse
import subprocess
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
from release_gate import built_executables, check_package

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('build', type=Path)
parser.add_argument('archive', type=Path)
parser.add_argument('--build-only', action='store_true', help='Build and verify the distribution without running native relocation')
args = parser.parse_args()
build, archive = args.build, args.archive
if args.build_only:
    subprocess.run(['cmake', '--build', str(build), '--target', 'package_static_dist', '-j8'], check=True)
try:
    check_package(archive, built_executables(build))
except (OSError, ValueError, tarfile.TarError) as error:
    raise SystemExit(f'Package validation failed: {error}. Rebuild fc.package_build in the configured build environment before running manual tests.')
print('PASS package executable hashes match the built fc, Fresh and 7zr', flush=True)
if args.build_only:
    raise SystemExit(0)
# Manual relocation consumes the exact archive validated above. It must not
# invoke a compiler or require the build environment's Cargo/Rust configuration.
raise SystemExit(subprocess.run([sys.executable, str(Path(__file__).with_name('test_packaged_script.py')), str(archive)]).returncode)
