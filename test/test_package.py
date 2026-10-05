"""Build a distribution and execute its embedded Lua framework outside the checkout."""
from pathlib import Path
import argparse
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('build', type=Path)
parser.add_argument('archive', type=Path)
parser.add_argument('--build-only', action='store_true')
args = parser.parse_args()
build, archive = args.build, args.archive
subprocess.run(['cmake', '--build', str(build), '--target', 'package_static_dist', '-j8'], check=True)
if args.build_only:
    # The automatic release lane also checks every packaged executable's hash.
    if not archive.is_file() or archive.stat().st_size == 0:
        raise SystemExit('package target did not produce an archive')
    print('PASS distribution archive built')
    raise SystemExit(0)
raise SystemExit(subprocess.run([sys.executable, str(Path(__file__).with_name('test_packaged_script.py')), str(archive)]).returncode)
