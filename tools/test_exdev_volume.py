#!/usr/bin/env python3
"""Run the real EXDEV case on a disposable macOS APFS volume, then detach it."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary',type=Path,default=Path('build/fc_file_fault_tests'))
args=parser.parse_args()
if platform.system()!='Darwin':raise SystemExit('macOS hdiutil is required; Linux can use FC_TEST_EXDEV_ROOT=/dev/shm')
with tempfile.TemporaryDirectory(prefix='fc-exdev-') as directory:
    root=Path(directory);mount=root/'volume';mount.mkdir();image=root/'fixture.sparseimage';attached=False
    try:
        subprocess.run(['hdiutil','create','-quiet','-size','128m','-fs','APFS','-type','SPARSE','-volname','FC-EXDEV-fixture','-o',str(image)],check=True,timeout=30)
        subprocess.run(['hdiutil','attach','-quiet','-nobrowse','-mountpoint',str(mount),str(image)],check=True,timeout=30)
        attached=True
        subprocess.run([str(args.binary.resolve()),'exdev'],env=dict(os.environ,FC_TEST_EXDEV_ROOT=str(mount),FC_REQUIRE_EXDEV='1'),check=True,timeout=20)
        print('PASS actual EXDEV through distinct APFS fixture volume')
    finally:
        if attached or mount.is_mount():
            detached=subprocess.run(['hdiutil','detach','-quiet',str(mount)],timeout=30)
            if detached.returncode:
                subprocess.run(['hdiutil','detach','-force','-quiet',str(mount)],check=True,timeout=30)
