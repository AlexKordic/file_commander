"""Build a distribution and execute its embedded Lua framework outside the checkout."""
from pathlib import Path
import subprocess
import sys

build, archive = map(Path, sys.argv[1:])
subprocess.run(['cmake', '--build', str(build), '--target', 'package_static_dist', '-j8'], check=True)
subprocess.run([sys.executable, str(Path(__file__).with_name('test_packaged_script.py')), str(archive)], check=True)
