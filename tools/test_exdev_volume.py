#!/usr/bin/env python3
"""Run EXDEV or the manual lane on a disposable macOS APFS volume, then detach it."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
mode=parser.add_mutually_exclusive_group()
mode.add_argument('--binary',type=Path,default=Path('build/fc_file_fault_tests'))
mode.add_argument('--manual-build',type=Path,help='Run all manual-category tests from this build instead of only EXDEV')
args=parser.parse_args()
if platform.system()!='Darwin':raise SystemExit('macOS hdiutil is required; Linux can use FC_TEST_EXDEV_ROOT=/dev/shm')
with tempfile.TemporaryDirectory(prefix='fc-exdev-') as directory:
    root=Path(directory);mount=root/'volume';mount.mkdir();image=root/'fixture.sparseimage';attached=False
    try:
        subprocess.run(['hdiutil','create','-quiet','-size','128m','-fs','APFS','-type','SPARSE','-volname','FC-EXDEV-fixture','-o',str(image)],check=True,timeout=30)
        subprocess.run(['hdiutil','attach','-quiet','-nobrowse','-mountpoint',str(mount),str(image)],check=True,timeout=30)
        attached=True
        if mount.stat().st_dev == root.stat().st_dev:
            raise RuntimeError('EXDEV fixture must be on a distinct filesystem')
        command=([sys.executable,str(Path(__file__).with_name('run_test_lane.py')),'manual','--build',str(args.manual_build.resolve())]
                 if args.manual_build else [str(args.binary.resolve()),'exdev'])
        subprocess.run(command,env=dict(os.environ,FC_TEST_EXDEV_ROOT=str(mount),FC_REQUIRE_EXDEV='1'),check=True,timeout=1900 if args.manual_build else 20)
        print('PASS manual lane with APFS EXDEV fixture' if args.manual_build else 'PASS actual EXDEV through distinct APFS fixture volume')
    finally:
        if attached or mount.is_mount():
            detached=subprocess.run(['hdiutil','detach','-quiet',str(mount)],timeout=30)
            if detached.returncode:
                subprocess.run(['hdiutil','detach','-force','-quiet',str(mount)],check=True,timeout=30)
