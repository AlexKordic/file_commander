"""Versioned tutorial captures -> one measured presentation timeline.

No app, capture API, speech service, or browser is required to read this format.
All times on disk are integer nanoseconds; floating point is only used at tool
boundaries. Paths are relative to the recording root, never executable commands.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import struct
import zlib
from pathlib import Path

from . import SCHEMA

NS = 1_000_000_000


class MediaError(ValueError):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise MediaError(f'Cannot read {path}: {error}') from error


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.partial')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n')
    temporary.replace(path)


def load_catalog(path):
    """Portable list, schema-1 catalog object, or a host's lesson directory."""
    path = Path(path)
    if path.is_dir():
        lessons = [read_json(p) for p in path.glob('*.json') if p.name != 'chapters.json']
        chapters = read_json(path / 'chapters.json') if (path / 'chapters.json').exists() else []
    else:
        value = read_json(path)
        if isinstance(value, dict):
            if value.get('schema') != SCHEMA:
                raise MediaError('Unsupported narration catalog schema')
            lessons, chapters = value.get('lessons'), value.get('chapters', [])
        else:
            lessons, chapters = value, []
    if not isinstance(lessons, list) or not lessons or not all(isinstance(l, dict) and isinstance(l.get('id'), str) and l['id'] for l in lessons):
        raise MediaError('Catalog needs a nonempty list of identified lessons')
    if len({l['id'] for l in lessons}) != len(lessons):
        raise MediaError('Catalog lesson identities must be unique')
    if not isinstance(chapters, list):
        raise MediaError('Catalog chapters must be a list')
    return sorted(lessons, key=lambda lesson: lesson.get('order', 0)), chapters


def asset(root, name):
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise MediaError(f'Asset must have a relative path: {name!r}')
    path = (Path(root) / name).resolve()
    if not path.is_relative_to(Path(root).resolve()):
        raise MediaError(f'Asset escapes the recording directory: {name!r}')
    if not path.is_file():
        raise MediaError(f'Missing asset: {path}')
    return path


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def media_fingerprint(timeline):
    """Inputs that determine movie pixels, audio and their timing."""
    value = {key: timeline[key] for key in ('width', 'height', 'fps', 'duration_ns')}
    value['frames'] = [{key: frame[key] for key in ('pts_ns', 'path', 'sha256')} for frame in timeline['frames']]
    value['narration'] = [{key: clip[key] for key in ('start_ns', 'duration_ns', 'path', 'sha256')} for clip in timeline['narration']]
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def nanoseconds(value, label='time', positive=False):
    if isinstance(value, bool) or not isinstance(value, int) or value < (1 if positive else 0):
        raise MediaError(f'{label} must be a {"positive" if positive else "nonnegative"} integer in nanoseconds')
    return value


def png_size(path):
    with Path(path).open('rb') as stream:
        if stream.read(8) != b'\x89PNG\r\n\x1a\n':
            raise MediaError(f'Not a PNG: {path}')
        size, image_data = None, False
        while True:
            header = stream.read(8)
            if len(header) != 8:
                raise MediaError(f'Truncated PNG: {path}')
            length, kind = struct.unpack('>I4s', header)
            if length > Path(path).stat().st_size:
                raise MediaError(f'Invalid PNG chunk length: {path}')
            payload, checksum = stream.read(length), stream.read(4)
            if len(payload) != length or len(checksum) != 4:
                raise MediaError(f'Truncated PNG: {path}')
            if zlib.crc32(payload, zlib.crc32(kind)) != struct.unpack('>I', checksum)[0]:
                raise MediaError(f'PNG chunk checksum mismatch: {path}')
            if size is None:
                if kind != b'IHDR' or length != 13:
                    raise MediaError(f'Missing PNG image header: {path}')
                size = struct.unpack('>II', payload[:8])
            if kind == b'IDAT':
                image_data = True
            if kind == b'IEND':
                if length or not image_data or stream.read(1):
                    raise MediaError(f'PNG checksum/structure failure: {path}')
                return size


def slug(value):
    return re.sub(r'[^a-zA-Z0-9_-]+', '-', str(value)).strip('-') or 'step'


def stamp(ns, filename=False):
    ms = (ns + 500_000) // 1_000_000
    hours, ms = divmod(ms, 3_600_000)
    minutes, ms = divmod(ms, 60_000)
    seconds, ms = divmod(ms, 1000)
    return (f'{hours:02d}-{minutes:02d}-{seconds:02d}-{ms:03d}' if filename else
            f'{hours:02d}:{minutes:02d}:{seconds:02d}.{ms:03d}')


def load_capture(root, verify_hashes=True):
    """Read one completed capture; reject incomplete or inconsistent evidence."""
    root = Path(root).resolve()
    manifest = read_json(root / 'manifest.json')
    if manifest.get('schema') != SCHEMA or manifest.get('status') != 'complete':
        raise MediaError(f'{root}: capture is not a completed schema-{SCHEMA} take')
    if manifest.get('errors'):
        raise MediaError(f'{root}: capture errors: {manifest["errors"]}')
    width, height = manifest.get('width'), manifest.get('height')
    if any(isinstance(v, bool) or not isinstance(v, int) or v <= 0 or v % 2 for v in (width, height)):
        raise MediaError('Capture dimensions must be positive even pixel counts')
    duration = nanoseconds(manifest.get('duration_ns'), 'capture duration', positive=True)
    frames = manifest.get('frames', [])
    if not frames:
        raise MediaError(f'{root}: no retained frames')
    previous, sequences = -1, set()
    for frame in frames:
        pts = nanoseconds(frame.get('pts_ns'), 'frame timestamp')
        if pts <= previous or pts >= duration:
            raise MediaError('Frame timestamps must increase strictly within capture duration')
        previous = pts
        sequence = frame.get('sequence')
        if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0 or sequence in sequences:
            raise MediaError('Frame sequences must be unique integers')
        sequences.add(sequence)
        path = asset(root, frame.get('path'))
        if png_size(path) != (width, height):
            raise MediaError(f'Frame geometry changed: {path}')
        if verify_hashes and frame.get('sha256') != digest(path):
            raise MediaError(f'Frame checksum mismatch: {path}')
    if frames[0]['pts_ns'] != 0:
        raise MediaError('First retained frame must define presentation time zero')
    if 'source_samples' in manifest:
        counts = (manifest['source_samples'], manifest.get('coalesced_samples', 0))
        if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in counts):
            raise MediaError('Source frame counters must be nonnegative integers')
        native = sum('source_timestamp' in frame for frame in frames)
        if manifest['source_samples'] - manifest.get('coalesced_samples', 0) != native:
            raise MediaError('Changed source frames were not saved; this take is incomplete')
    events_path = root / 'events.jsonl'
    try:
        events = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()]
    except (OSError, ValueError) as error:
        raise MediaError(f'Cannot read capture event journal: {error}') from error
    previous = -1
    for event in events:
        at = nanoseconds(event.get('pts_ns'), 'event timestamp')
        if at < previous or at > duration:
            raise MediaError('Events must be ordered and lie within capture duration')
        previous = at
    return manifest, events


def compile_timeline(root):
    root = Path(root).resolve()
    course = read_json(root / 'course.json')
    if course.get('schema') != SCHEMA or not course.get('takes'):
        raise MediaError('Expected schema-1 course.json with at least one take')
    if course.get('status') not in (None, 'complete'):
        raise MediaError('Course recording is incomplete; finish or resume it before rendering')
    narration = read_json(root / 'narration/script.json') if (root / 'narration/script.json').exists() else {'clips': {}}
    timeline = dict(schema=SCHEMA, title=course.get('title', 'Tutorial'), language=narration.get('language', 'en'), duration_ns=0,
                    width=0, height=0, fps=course.get('fps', 30), chapters=[], lessons=[], steps=[], actions=[],
                    frames=[], narration=[], takes=[])
    fps = timeline['fps']
    if isinstance(fps, bool) or not isinstance(fps, int) or not 1 <= fps <= 60:
        raise MediaError('Frame rate must be an integer from 1 to 60')
    offset, seen_steps, seen_lessons = 0, set(), set()
    for entry in course['takes']:
        take_root = asset(root, entry['manifest']).parent
        manifest, events = load_capture(take_root)
        lesson = manifest.get('lesson', {})
        lesson_id = lesson.get('id')
        if not lesson_id or lesson_id in seen_lessons:
            raise MediaError(f'Duplicate or empty lesson identity: {lesson_id}')
        seen_lessons.add(lesson_id)
        size = (manifest['width'], manifest['height'])
        if timeline['width'] and size != (timeline['width'], timeline['height']):
            raise MediaError('All course takes must use the same chosen resolution')
        timeline['width'], timeline['height'] = size
        duration = manifest['duration_ns']
        chapter_id = lesson.get('chapter', 'tutorial')
        chapter = next((c for c in timeline['chapters'] if c['id'] == chapter_id), None)
        if chapter is not None and timeline['lessons'] and timeline['lessons'][-1]['chapter'] != chapter_id:
            raise MediaError('Lessons belonging to one chapter must be contiguous')
        if chapter is None:
            chapter = dict(id=chapter_id, title=lesson.get('chapter_title', chapter_id), start_ns=offset, end_ns=offset)
            timeline['chapters'].append(chapter)
        chapter['end_ns'] = offset + duration
        timeline['lessons'].append(dict(id=lesson_id, title=lesson.get('title', lesson_id), chapter=chapter_id,
                                        start_ns=offset, end_ns=offset + duration))
        for frame in manifest['frames']:
            timeline['frames'].append(dict(frame, pts_ns=offset + frame['pts_ns'], source_pts_ns=frame['pts_ns'],
                                           path=str((take_root / frame['path']).relative_to(root)), lesson=lesson_id))
        active, actions = None, {}
        for event in events:
            at, kind = offset + event['pts_ns'], event.get('type')
            if kind == 'segment_started':
                if active:
                    raise MediaError('A presentation segment started before the previous one completed')
                identity = event.get('id')
                if not identity or identity in seen_steps:
                    raise MediaError(f'Duplicate or empty presentation step: {identity}')
                seen_steps.add(identity)
                active = dict(id=identity, title=event.get('title', identity), text=event.get('text', ''),
                              start_ns=at, end_ns=offset + duration, lesson=lesson_id, chapter=chapter_id)
                clip = narration.get('clips', {}).get(identity)
                if clip:
                    audio = asset(root, clip['path'])
                    if clip.get('sha256') != digest(audio):
                        raise MediaError(f'Narration checksum mismatch: {identity}')
                    timeline['narration'].append(dict(clip, id=identity, start_ns=at))
                    active['text'] = clip.get('text', active['text'])
            elif kind == 'segment_completed':
                if not active or active['id'] != event.get('id'):
                    raise MediaError('Unpaired presentation segment completion')
                active['end_ns'] = at
                timeline['steps'].append(active)
                active = None
            elif kind == 'step_started':
                identity = event.get('id')
                if not identity or identity in actions:
                    raise MediaError('Missing or duplicate raw action identity')
                actions[identity] = dict(id=identity, action=event.get('action'), start_ns=at, lesson=lesson_id)
            elif kind == 'step_completed':
                action = actions.pop(event.get('id'), None)
                if not action:
                    raise MediaError('Unpaired raw action completion')
                timeline['actions'].append(dict(action, end_ns=at))
        if active:
            raise MediaError(f'Unfinished presentation segment: {active["id"]}')
        if actions:
            raise MediaError(f'Unfinished actions: {list(actions)}')
        timeline['takes'].append(dict(manifest=entry['manifest'], start_ns=offset, end_ns=offset + duration,
                                      source=manifest.get('provenance', {})))
        offset += duration
    timeline['duration_ns'] = offset
    expected = course.get('expected_lessons')
    if expected is not None and expected != [lesson['id'] for lesson in timeline['lessons']]:
        raise MediaError('Course is missing requested lessons or its order changed')
    previous_end = 0
    steps = {step['id']: step for step in timeline['steps']}
    if not steps:
        raise MediaError('No authored presentation steps in this course')
    for step in timeline['steps']:
        if step['end_ns'] <= step['start_ns'] or step['start_ns'] < previous_end:
            raise MediaError('Presentation steps must have positive, non-overlapping durations')
        previous_end = step['end_ns']
    previous_audio_end = 0
    for clip in timeline['narration']:
        duration = nanoseconds(clip.get('duration_ns'), 'audio duration', positive=True)
        end = clip['start_ns'] + duration
        if clip['start_ns'] < previous_audio_end or end > steps[clip['id']]['end_ns'] + 1_000_000:
            raise MediaError(f'Narration does not fit its visual step: {clip["id"]}')
        previous_audio_end = end
    return timeline


def subtitles(timeline, srt=False):
    cues = []
    for step in timeline['steps']:
        text = step.get('text') or step['title']
        clip = next((c for c in timeline['narration'] if c['id'] == step['id']), None)
        end = min(step['end_ns'], step['start_ns'] + clip['duration_ns']) if clip else step['end_ns']
        # Utterance-level cues, not fabricated word alignment.
        start_stamp, end_stamp = stamp(step['start_ns']), stamp(end)
        if srt:
            start_stamp, end_stamp = start_stamp.replace('.', ','), end_stamp.replace('.', ',')
        text = text.replace('-->', '→').replace('\r', '').strip()
        cues.append(f'{len(cues) + 1}\n{start_stamp} --> {end_stamp}\n{text}\n')
    return ('' if srt else 'WEBVTT\n\n') + '\n'.join(cues)
