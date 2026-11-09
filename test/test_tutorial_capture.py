#!/usr/bin/env python3
"""Manual macOS capture fault qualification on owned windows and an owned volume.

Requires a normal desktop with Screen Recording permission. Never changes the
user's permission settings or uses the user's FC profile/editor. Outputs are
retained in --out. The small disk image is always detached after its test.
"""
import argparse
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from tutorial_media.core import read_json, write_json
from tutorial_media.supervise import read_optional, stop_owned


def eventually(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if value := predicate():
            return value
        time.sleep(.05)
    raise AssertionError('Timed out waiting for capture result')


def scenario(name, root, example, capture, geometry, lesson, prepare=None, folder=None):
    take = root / name
    take.mkdir()
    session = take / 'session'; session.mkdir()
    folder = folder or take
    folder.mkdir(exist_ok=True)
    if prepare:
        prepare(folder)
    script = take / 'lesson.json'; write_json(script, lesson)
    config = take / 'config.json'
    write_json(config, dict(schema=1, folder=str(folder), session=str(session),
                            lesson=dict(id=name, title=name), geometry=geometry, fps=30,
                            scriptPath=str(script)))
    host = recorder = None
    try:
        with (take / 'host.log').open('w') as host_log, (take / 'recorder.log').open('w') as recorder_log:
            host = subprocess.Popen([str(example), '--record-session', str(config)], stdout=host_log, stderr=subprocess.STDOUT)
            recorder = subprocess.Popen([str(capture), str(config)], stdout=recorder_log, stderr=subprocess.STDOUT)
            result = eventually(lambda: read_optional(session / 'capture_result.json'))
            assert result['status'] == 'failed', (name, result)
            manifest = read_optional(folder / 'manifest.json')
            assert manifest is None or manifest.get('status') != 'complete', 'A failed take must never look complete'
            return dict(name=name, status='passed', capture_error=result.get('error'),
                        manifest_status=manifest.get('status') if manifest else 'not created')
    finally:
        stop_owned(host, session); stop_owned(recorder)


def disk_full(root, example, capture, geometry, lesson):
    image = root / 'full.sparseimage'
    mount = root / 'full-volume'; mount.mkdir()
    attached = False
    try:
        subprocess.run(['hdiutil', 'create', '-quiet', '-size', '128m', '-fs', 'APFS', '-type', 'SPARSE',
                        '-volname', 'Tutorial-capture-fixture', '-o', str(image)], check=True, timeout=30)
        subprocess.run(['hdiutil', 'attach', '-quiet', '-nobrowse', '-mountpoint', str(mount), str(image)], check=True, timeout=30)
        attached = True
        assert mount.stat().st_dev != root.stat().st_dev
        capture_folder = mount / 'capture'; capture_folder.mkdir()
        # Allocate real blocks only inside this disposable 128 MiB image.
        observed = False
        with (mount / 'filler').open('wb', buffering=0) as output:
            for size in (1024 * 1024, 4096):
                while True:
                    try:
                        output.write(bytes(size))
                    except OSError as error:
                        if error.errno != errno.ENOSPC:
                            raise
                        observed = True
                        break
        assert observed, 'The fixture did not produce an actual ENOSPC'
        result = scenario('disk-full', root, example, capture, geometry, lesson, folder=capture_folder)
        result['real_enospc'] = True
        return result
    finally:
        if attached or mount.is_mount():
            result = subprocess.run(['hdiutil', 'detach', '-quiet', str(mount)], timeout=30)
            if result.returncode:
                subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(mount)], check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--example', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This manual qualification requires macOS')
    root = args.out.resolve(); root.mkdir(parents=True, exist_ok=False)
    os.chmod(root, 0o700)
    geometry = dict(x=70, y=70, pointsWidth=900, pointsHeight=650, scale=2, width=1800, height=1300)
    lesson = dict(id='fault', title='Capture fault qualification', steps=[
        dict(id='fault.start', caption='Capture fault qualification', presentation=dict(
            id='fault.present', title='Capture fault qualification', narration='This is a capture fault test.')),
        dict(id='fault.hold', pause=1500)])
    reports = []
    try:
        reports.append(scenario('unwritable-frames', root, args.example.resolve(), args.capture.resolve(), geometry,
                                lesson, prepare=lambda folder: (folder / 'frames').write_text('a file blocks the output directory')))
        resized = dict(lesson, steps=lesson['steps'] + [dict(id='fault.resize', resize_window=50), dict(id='fault.wait', pause=1500)])
        reports.append(scenario('geometry-changed', root, args.example.resolve(), args.capture.resolve(), geometry, resized))
        assert 'changed size' in reports[-1]['capture_error'], reports[-1]
        reports.append(disk_full(root, args.example.resolve(), args.capture.resolve(), geometry, lesson))
    finally:
        write_json(root / 'results.json', reports)
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
