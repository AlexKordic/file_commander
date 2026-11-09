"""Local media qualification and a portable handoff. No publication actions."""
from __future__ import annotations

from array import array
import math
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import wave

from .core import MediaError, NS, asset, compile_timeline, digest, read_json, write_json, media_fingerprint
from .render import html_player, narration_track, probe
from .speech import executable, run


def samples(stream, start, count):
    stream.setpos(start)
    data = array('h', stream.readframes(count))
    if sys.byteorder != 'little':
        data.byteswap()
    return data


def alignment(reference, decoded, start, count=48000, radius=2880):
    """Normalized correlation around a known source offset; report measured lag."""
    start = max(radius, min(start, reference.getnframes() - count - radius))
    ref = samples(reference, start, count)
    candidate = samples(decoded, start - radius, count + radius * 2)
    if len(ref) != count or len(candidate) != count + radius * 2:
        raise MediaError('Decoded audio is shorter than its source timeline')

    def score(lag, stride):
        left, right = ref[::stride], candidate[radius + lag:radius + lag + count:stride]
        a = sum(value * value for value in left)
        b = sum(value * value for value in right)
        if not a or not b:
            return -1
        return sum(x * y for x, y in zip(left, right)) / math.sqrt(a * b)

    coarse = max(range(-radius, radius + 1, 16), key=lambda lag: score(lag, 16))
    best = max(range(max(-radius, coarse - 16), min(radius, coarse + 16) + 1), key=lambda lag: score(lag, 1))
    return dict(source_sample=start, offset_samples=best, offset_ms=best / 48, correlation=score(best, 1))


def qualify(root, browser_report=None):
    root = Path(root).resolve()
    timeline = compile_timeline(root)
    result = read_json(root / 'validation.json')
    movie = root / 'render/tutorial.mp4'
    if result.get('video_sha256') != digest(movie):
        raise MediaError('Movie changed after rendering; rebuild before qualification')
    media = media_fingerprint(timeline)
    rendered = result.get('rendered_media_sha256') or media_fingerprint(read_json(root / 'render/timeline.json'))
    if rendered != media:
        raise MediaError('Source media changed since rendering; rebuild before qualification')
    info = probe(movie)
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    if (video['width'], video['height']) != (timeline['width'], timeline['height']):
        raise MediaError('Movie and source capture dimensions differ')
    duration = timeline['duration_ns'] / NS
    if abs(float(info['format']['duration']) - duration) > 1 / timeline['fps'] + .025:
        raise MediaError('Movie and source timeline duration differ')
    # Decode every packet, rather than checking only container metadata.
    already_decoded = result.get('all_packets_decoded') and result.get('qualified_media_sha256') == media
    if not already_decoded:
        run([executable('ffmpeg'), '-v', 'error', '-xerror', '-nostdin', '-i', str(movie), '-f', 'null', '-'],
            timeout=max(180, duration * 3))
    clips = [c for c in timeline['narration'] if c['duration_ns'] >= 2 * NS]
    offsets = result.get('audio_alignment', []) if already_decoded else []
    if clips and not already_decoded:
        source = root / 'render/narration.wav'
        narration_track(root, timeline, source)
        with tempfile.TemporaryDirectory(prefix='tutorial-audio-') as temporary:
            decoded = Path(temporary) / 'decoded.wav'
            run([executable('ffmpeg'), '-v', 'error', '-xerror', '-nostdin', '-y', '-i', str(movie), '-vn',
                 '-ar', '48000', '-ac', '1', '-c:a', 'pcm_s16le', str(decoded)], timeout=max(120, duration))
            chosen = [clips[0], clips[len(clips) // 2], clips[-1]]
            with wave.open(str(source), 'rb') as original, wave.open(str(decoded), 'rb') as delivered:
                for clip in chosen:
                    at = round((clip['start_ns'] / NS + .35) * 48000)
                    evidence = alignment(original, delivered, at)
                    evidence['segment'] = clip['id']
                    if evidence['correlation'] < .85 or abs(evidence['offset_samples']) > 1024 + 48000 / timeline['fps']:
                        raise MediaError(f'Audio alignment failed: {evidence}')
                    offsets.append(evidence)
            if max(r['offset_samples'] for r in offsets) - min(r['offset_samples'] for r in offsets) > 48000 / timeline['fps']:
                raise MediaError('Audio drift exceeds one delivery frame')
    # Refresh the page from the current template without re-encoding its movie.
    write_json(root / 'render/timeline.json', timeline)
    html_player(root / 'standalone.html', timeline, movie, root / 'render/poster.png', root / 'render/captions.vtt')
    html_player(root / 'web/index.html', timeline, movie, root / 'render/poster.png', root / 'render/captions.vtt', standalone=False)
    result.update(source_frame_accounting='passed', all_packets_decoded=True, audio_alignment=offsets,
                  rendered_media_sha256=media, qualified_media_sha256=media,
                  standalone_sha256=digest(root / 'standalone.html'), standalone_bytes=(root / 'standalone.html').stat().st_size)
    old_browser = result.get('browser_qualification')
    if isinstance(old_browser, list) and any(r.get('standalone_sha256') != result['standalone_sha256'] for r in old_browser):
        result['browser_qualification'] = 'page changed; rerun browser qualification'
    if browser_report:
        reports = read_json(browser_report)
        if not isinstance(reports, list) or not {'chromium', 'firefox', 'webkit'}.issubset({r.get('engine') for r in reports}) or any(r.get('status') != 'passed' for r in reports):
            raise MediaError('Browser qualification did not pass every required engine')
        if any(r.get('standalone_sha256') != result['standalone_sha256'] for r in reports):
            raise MediaError('Browser report refers to a different standalone page; rerun the browser checks')
        result['browser_qualification'] = reports
    write_json(root / 'validation.json', result)
    return result


def handoff(root):
    root = Path(root).resolve()
    timeline = compile_timeline(root)
    validation = read_json(root / 'validation.json')
    if validation.get('video_sha256') != digest(root / 'render/tutorial.mp4') or not validation.get('all_packets_decoded'):
        raise MediaError('Run media qualification before preparing the handoff')
    if validation.get('standalone_sha256') != digest(root / 'standalone.html') or validation.get('qualified_media_sha256') != media_fingerprint(timeline):
        raise MediaError('Handoff sources changed after qualification; qualify again')
    folder = root / 'handoff'; folder.mkdir(exist_ok=True)
    copies = {'standalone.html': 'standalone.html', 'render/tutorial.mp4': 'tutorial.mp4',
              'render/captions.vtt': 'captions.vtt', 'render/captions.srt': 'captions.srt',
              'render/poster.png': 'poster.png', 'render/timeline.json': 'timeline.json',
              'render/images.json': 'images.json', 'validation.json': 'validation.json'}
    for source, destination in copies.items():
        shutil.copyfile(root / source, folder / destination)
    archive = folder / 'capture-source.tar.gz'
    temporary = archive.with_suffix('.partial')
    # Whitelist sources needed for a portable rebuild. Never include profiles,
    # app bundles, helper configs, debug logs, credentials or signing material.
    sources = {'course.json'}
    for take in timeline['takes']:
        manifest = asset(root, take['manifest'])
        take_root = manifest.parent
        sources.update(str(p.relative_to(root)) for p in [manifest, take_root / 'events.jsonl', take_root / 'lesson.json'] if p.is_file())
    sources.update(frame['path'] for frame in timeline['frames'])
    if (root / 'narration/script.json').exists():
        sources.add('narration/script.json')
        sources.update(clip['path'] for clip in timeline['narration'])
    try:
        with tarfile.open(temporary, 'w:gz', compresslevel=1) as output:
            for name in sorted(sources):
                output.add(asset(root, name), arcname=name, recursive=False)
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    (folder / 'README.md').write_text(
        '# Tutorial handoff\n\nOpen `standalone.html`; it needs no adjacent files or network.\n\n'
        '`tutorial.mp4` is the ordinary narrated movie. Captions, timeline, poster and validation are alongside it.\n\n'
        'Extract `capture-source.tar.gz` into a new directory to recover the retained PNGs, event journals, '
        'course, authored lessons and source narration. With ExplainerKit tools and FFmpeg available, run '
        '`tutorial_media.py build EXTRACTED_DIRECTORY` to rebuild without the host application.\n\n'
        'No publishing has occurred. Review narration/voice terms and the validation report before distribution. '
        'Use the separate publication README snippet only after real URLs have been verified.\n')
    checksums = {p.name: dict(bytes=p.stat().st_size, sha256=digest(p)) for p in folder.iterdir()
                 if p.is_file() and p.name != 'checksums.json'}
    write_json(folder / 'checksums.json', checksums)
    return folder
