"""Own isolated tutorial hosts and a recorder that survives their restarts.

Hosts implement the JSON session protocol. This module does not import any FC
code and never commits, pushes, uploads, or deploys its output.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import time
import tempfile

from .core import MediaError, compile_timeline, load_capture, read_json, write_json, load_catalog
from .render import build
from .speech import executable, prepare


def host_binary(app):
    app = Path(app).resolve()
    if app.suffix == '.app':
        with (app / 'Contents/Info.plist').open('rb') as stream:
            name = plistlib.load(stream)['CFBundleExecutable']
        return app / 'Contents/MacOS' / name
    return app


def read_optional(path):
    try:
        return read_json(path)
    except MediaError:
        return None


def stop_owned(process, session=None):
    """Only handles we spawned, or replacement PIDs carrying our exact session."""
    candidates = set()
    if process and process.poll() is None:
        candidates.add(process.pid)
    if session:
        host = read_optional(Path(session) / 'host.json')
        if host and isinstance(host.get('pid'), int):
            pid = host['pid']
            result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'uid=,args='], capture_output=True, text=True)
            line = result.stdout.strip()
            if line and line.split(None, 1)[0] == str(os.getuid()) and str(Path(session).parent / 'config.json') in line:
                candidates.add(pid)
    for pid in candidates:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if process and process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)


def acquire_desktop(root):
    """One native tutorial owns keyboard focus at a time; OS releases on exit."""
    try:
        import fcntl
    except ImportError as error:
        raise MediaError('The native capture supervisor requires macOS; portable image builds work separately') from error
    path = Path(tempfile.gettempdir()) / f'explainerkit-desktop-{os.getuid()}.lock'
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    handle = os.fdopen(descriptor, 'r+')
    try:
        waiting = False
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return handle
            except BlockingIOError:
                if not waiting:
                    print('Waiting for the other tutorial recording to release desktop focus…', flush=True)
                    write_json(root / 'progress.json', dict(status='waiting', message='Another tutorial is recording'))
                    waiting = True
                time.sleep(.2)
    except BaseException:
        handle.close()
        raise


def record(root, app, capture_binary, catalog, geometry, selected=None, voice=None, rate=180,
           imported=None, fps=30, silent=False, resume=False, render=True, appearance='system', title='Tutorial', language='en', retake=None,
           host_options=None):
    os.umask(0o077)
    root, catalog = Path(root).resolve(), Path(catalog).resolve()
    root.mkdir(parents=True, exist_ok=True)
    if host_options is not None and not isinstance(host_options, dict):
        raise MediaError('Host options must be a JSON object')
    with tempfile.TemporaryFile(dir=root) as probe:
        probe.write(b'Tutorial export write preflight\n')
        probe.flush(); os.fsync(probe.fileno())
    if (root / 'course.json').exists() and not resume:
        raise MediaError('Recording directory already contains a course; choose a new directory or use --resume')
    executable('ffmpeg'); executable('ffprobe')
    binary, capture_binary = host_binary(app), Path(capture_binary).resolve()
    for path in (binary, capture_binary):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise MediaError(f'Tutorial executable is unavailable: {path}')
    lessons, chapters = load_catalog(catalog)
    if selected:
        unknown = set(selected) - {lesson['id'] for lesson in lessons}
        if unknown:
            raise MediaError(f'Unknown lessons: {sorted(unknown)}')
        lessons = [lesson for lesson in lessons if lesson['id'] in set(selected)]
    if not lessons:
        raise MediaError('Choose at least one lesson to record')
    if retake and (not resume or set(retake) - {lesson['id'] for lesson in lessons}):
        raise MediaError('--retake requires --resume and lesson IDs present in this course selection')
    required = ('x', 'y', 'pointsWidth', 'pointsHeight', 'scale')
    if any(isinstance(geometry.get(key), bool) or not isinstance(geometry.get(key), (int, float)) or
           not math.isfinite(geometry[key]) for key in required):
        raise MediaError('Capture geometry needs x, y, pointsWidth, pointsHeight, and scale')
    if geometry['scale'] <= 0 or geometry['pointsWidth'] <= 0 or geometry['pointsHeight'] <= 0:
        raise MediaError('Window size and scale must be positive')
    if not isinstance(fps, int) or isinstance(fps, bool) or not 1 <= fps <= 60:
        raise MediaError('Capture frame rate must be an integer from 1 to 60')
    geometry = dict(geometry, width=(math.floor(geometry['pointsWidth'] * geometry['scale'] + .5) + 1) // 2 * 2,
                    height=(math.floor(geometry['pointsHeight'] * geometry['scale'] + .5) + 1) // 2 * 2)
    # Estimate compressed PNG storage, not a promise about the encoded movie.
    estimate = max(512 * 1024 * 1024, int(geometry['width'] * geometry['height'] * fps *
                                       sum(lesson.get('duration', 60) for lesson in lessons) * .12))
    if shutil.disk_usage(root).free < estimate:
        raise MediaError(f'Not enough free space for retained images; estimated requirement {estimate / 1024**3:.1f} GiB')
    display = json.loads(subprocess.check_output([str(capture_binary), '--describe-display'], text=True, timeout=20))
    if not display.get('capture_permission'):
        raise MediaError('Enable Screen Recording permission for the tutorial recorder in macOS System Settings, then retry')
    narration = None
    if not silent:
        prepare(catalog, root, [lesson['id'] for lesson in lessons], voice, rate, imported, language)
        narration = str(root / 'narration/script.json')
    chapter_titles = {chapter['id']: chapter['title'] for chapter in chapters}
    course = dict(schema=1, status='recording', title=title, fps=fps, takes=[], expected_lessons=[lesson['id'] for lesson in lessons])
    write_json(root / 'course.json', course)
    # A short, disposable fixture path keeps developer checkout/user names out
    # of the pictures. This directory is owned by this supervisor only.
    # macOS filesystem events report /private/tmp, not its /tmp symlink.
    # Give the engine and watchers one canonical spelling of every demo path.
    fixture_home = Path(tempfile.mkdtemp(prefix='tutorial-media-', dir='/tmp')).resolve()
    initial_path = fixture_home / 'Tutorial'
    initial_path.mkdir()
    desktop = None
    try:
        desktop = acquire_desktop(root)
        for lesson in lessons:
            take = root / 'capture' / lesson['id']
            manifest = take / 'manifest.json'
            if resume and lesson['id'] not in set(retake or []) and manifest.exists() and read_json(manifest).get('status') == 'complete':
                load_capture(take)
                previous_config = read_json(take / 'config.json')
                if (read_json(take / 'lesson.json') != lesson or previous_config.get('geometry') != geometry or
                        previous_config.get('hostOptions', {}) != (host_options or {})):
                    raise MediaError(f'{lesson["id"]}: completed take uses different lesson content, geometry, or host options; start a new course')
                course['takes'].append(dict(manifest=str(manifest.relative_to(root))))
                write_json(root / 'course.json', course)
                print(f'Reusing completed take: {lesson["id"]}', flush=True)
                continue
            if take.exists():
                # Failed takes remain available as evidence, never silently replaced.
                previous = read_optional(manifest)
                suffix = '.previous-' if previous and previous.get('status') == 'complete' else '.failed-'
                backup = take.with_name(take.name + suffix + str(time.time_ns()))
                take.rename(backup)
            session = take / 'session'; session.mkdir(parents=True)
            script_path = take / 'lesson.json'; write_json(script_path, lesson)
            config = dict(schema=1, folder=str(take), session=str(session),
                          lesson=dict(id=lesson['id'], title=lesson['title'], chapter=lesson.get('chapter', 'tutorial'),
                                      chapter_title=chapter_titles.get(lesson.get('chapter'), lesson.get('chapter', 'Tutorial'))),
                          geometry=geometry, fps=fps, narration=narration, scriptPath=str(script_path), appearance=appearance,
                          initialPath=str(initial_path))
            if host_options is not None:
                config['hostOptions'] = host_options
            config_path = take / 'config.json'; write_json(config_path, config)
            write_json(root / 'progress.json', dict(status='recording', lesson=lesson['id'], completed=len(course['takes']), total=len(lessons)))
            print(f'Recording {lesson["id"]} ({len(course["takes"]) + 1}/{len(lessons)})', flush=True)
            host = recorder = None
            environment = dict(os.environ)
            # The owned host has its own profile and fixture world. Preserve the
            # normal user's HOME for macOS services; the host isolates its state.
            environment.pop('DYLD_INSERT_LIBRARIES', None)
            try:
                with (take / 'recorder.log').open('w') as capture_log, (take / 'host.log').open('w') as host_log:
                    recorder = subprocess.Popen([str(capture_binary), str(config_path)], env=environment, stdout=capture_log, stderr=subprocess.STDOUT)
                    host = subprocess.Popen([str(binary), '--record-session', str(config_path), '--record-take', lesson['id'],
                                             '--profile', str(root / 'profile'), '--tutorial-world', str(fixture_home / 'world')],
                                            cwd=initial_path, env=environment, stdout=host_log, stderr=subprocess.STDOUT)
                    timeout = max(240, lesson.get('duration', 60) * 8)
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        result = read_optional(session / 'capture_result.json')
                        if result:
                            if result.get('status') != 'complete':
                                raise MediaError(f'{lesson["id"]}: {result.get("error", "capture failed")}')
                            break
                        if recorder.poll() is not None:
                            raise MediaError(f'{lesson["id"]}: recorder exited ({recorder.returncode}); see {take / "recorder.log"}')
                        state = read_optional(session / 'host.json')
                        if host.poll() is not None and not state:
                            raise MediaError(f'{lesson["id"]}: host exited before preparing; see {take / "host.log"}')
                        if state and state.get('status') == 'failed':
                            raise MediaError(f'{lesson["id"]}: {state.get("error", "host failed")}')
                        time.sleep(.1)
                    else:
                        raise MediaError(f'{lesson["id"]}: exceeded its {timeout}s recording deadline')
                    recorder.wait(timeout=20)
                    load_capture(take)
                    # Allow the host to restore its demo state and stop its
                    # private editor normally before falling back to cleanup.
                    if host.poll() is None:
                        try:
                            host.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            pass
            finally:
                if recorder and recorder.poll() is None and not (session / 'capture_result.json').exists():
                    write_json(session / 'host.json', dict(schema=1, pid=host.pid if host else 0,
                                                          status='failed', error='Recording supervisor stopped this take'))
                    try:
                        recorder.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                stop_owned(host, session)
                stop_owned(recorder)
            course['takes'].append(dict(manifest=str(manifest.relative_to(root))))
            write_json(root / 'course.json', course)
        desktop.close(); desktop = None
        course['status'] = 'complete'
        write_json(root / 'course.json', course)
        compile_timeline(root)
        if render:
            write_json(root / 'progress.json', dict(status='encoding', completed=len(lessons), total=len(lessons)))
            build(root)
        write_json(root / 'progress.json', dict(status='complete', completed=len(lessons), total=len(lessons)))
    except BaseException as error:
        course['status'] = 'failed'; course['error'] = str(error)
        write_json(root / 'course.json', course)
        write_json(root / 'progress.json', dict(status='failed', error=str(error), completed=len(course['takes']), total=len(lessons)))
        raise
    finally:
        shutil.rmtree(fixture_home, ignore_errors=True)
        if desktop:
            desktop.close()
