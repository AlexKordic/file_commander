"""Image reconstruction, narration muxing, and offline/hosted publication files."""
from __future__ import annotations

import base64
import html
import json
from pathlib import Path
import shutil
import wave

from .core import MediaError, NS, asset, compile_timeline, digest, stamp, subtitles, write_json, media_fingerprint, slug
from .speech import executable, pcm_duration, run


def ffquote(path):
    if '\n' in str(path) or '\r' in str(path):
        raise MediaError('Media asset filenames cannot contain line breaks')
    return "'" + str(path).replace("'", "'\\''") + "'"


def silence(output, frames):
    while frames:
        chunk = min(frames, 48000)
        output.writeframesraw(b'\0' * (chunk * 2))
        frames -= chunk


def narration_track(root, timeline, destination):
    with wave.open(str(destination), 'wb') as output:
        output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        cursor = 0
        for clip in timeline['narration']:
            start = round(clip['start_ns'] * 48000 / NS)
            if start < cursor:
                raise MediaError(f'Narration overlap at {clip["id"]}')
            silence(output, start - cursor)
            source = asset(root, clip['path'])
            duration = pcm_duration(source)
            if abs(duration - clip['duration_ns']) > 1:
                raise MediaError(f'Audio duration metadata changed: {clip["id"]}')
            with wave.open(str(source), 'rb') as audio:
                while data := audio.readframes(48000):
                    output.writeframesraw(data)
                cursor = start + audio.getnframes()
        total = round(timeline['duration_ns'] * 48000 / NS)
        if cursor > total:
            raise MediaError('Narration extends past video end')
        silence(output, total - cursor)


def chapter_metadata(timeline):
    def escape(value):
        return str(value).replace('\\', '\\\\').replace('\n', ' ').replace('=', '\\=').replace(';', '\\;').replace('#', '\\#')
    out = f';FFMETADATA1\ntitle={escape(timeline["title"])}\n'
    for chapter in timeline['chapters']:
        out += (f'[CHAPTER]\nTIMEBASE=1/1000000000\nSTART={chapter["start_ns"]}\n'
                f'END={chapter["end_ns"]}\ntitle={escape(chapter["title"])}\n')
    return out


def html_player(destination, timeline, movie, poster, captions, standalone=True):
    template = Path(__file__).with_name('player.html').read_text()
    # Escaping '<' prevents </script> embedded in lesson text from ending JSON.
    data = json.dumps({key: value for key, value in timeline.items() if key not in ('frames', 'actions', 'narration', 'takes')},
                      ensure_ascii=False, allow_nan=False).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    replacements = {'__TITLE__': html.escape(timeline['title'], quote=True), '__TIMELINE__': data,
                    '__LANGUAGE__': html.escape(timeline.get('language', 'en'), quote=True),
                    '__POSTER__': 'data:image/png;base64,' + base64.b64encode(poster.read_bytes()).decode(),
                    '__CAPTIONS__': base64.b64encode(captions.read_bytes()).decode(),
                    '__EXTERNAL_VIDEO__': 'null' if standalone else json.dumps(movie.name)}
    for key, value in replacements.items():
        template = template.replace(key, value)
    before, after = template.split('__MOVIE__')
    with destination.open('w') as output:
        output.write(before)
        if standalone:
            with movie.open('rb') as source:
                while chunk := source.read(3 * 65536):
                    output.write(base64.b64encode(chunk).decode('ascii'))
        output.write(after)


def probe(path):
    return json.loads(run([executable('ffprobe'), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], timeout=30).stdout)


def build(root, quality=18, threads=4, title=None):
    root = Path(root).resolve()
    timeline = compile_timeline(root)
    if title:
        timeline['title'] = title
    render = root / 'render'
    render.mkdir(exist_ok=True)
    (root / 'validation.json').unlink(missing_ok=True)
    write_json(render / 'timeline.json', timeline)
    (render / 'captions.vtt').write_text(subtitles(timeline))
    (render / 'captions.srt').write_text(subtitles(timeline, srt=True))
    concat = ['ffconcat version 1.0']
    frames = timeline['frames']
    for i, frame in enumerate(frames):
        end = frames[i + 1]['pts_ns'] if i + 1 < len(frames) else timeline['duration_ns']
        if end <= frame['pts_ns']:
            raise MediaError('Invalid image interval in final timeline')
        concat += ['file ' + ffquote(asset(root, frame['path'])), 'option framerate 1000000',
                   f'duration {(end - frame["pts_ns"]) / NS:.9f}']
    # Repeating the final input allows the concat demuxer to realize its hold.
    concat += ['file ' + ffquote(asset(root, frames[-1]['path'])), 'option framerate 1000000']
    (render / 'frames.ffconcat').write_text('\n'.join(concat) + '\n')
    narration_track(root, timeline, render / 'narration.wav')
    (render / 'chapters.ffmetadata').write_text(chapter_metadata(timeline))
    movie = render / 'tutorial.mp4'
    temporary = render / 'tutorial.partial.mp4'
    duration = timeline['duration_ns'] / NS
    print(f'Assembling {len(frames)} images at {timeline["width"]}×{timeline["height"]}, {duration:.2f}s', flush=True)
    encoder = executable('ffmpeg')
    command = [encoder, '-v', 'warning', '-xerror', '-nostdin', '-y', '-err_detect', 'explode', '-f', 'concat', '-safe', '0',
               '-i', str(render / 'frames.ffconcat'), '-i', str(render / 'narration.wav'),
               '-i', str(render / 'chapters.ffmetadata'), '-map', '0:v:0', '-map', '1:a:0', '-map_metadata', '2',
               '-vf', f'fps={timeline["fps"]}', '-fps_mode', 'cfr', '-c:v', 'libx264', '-crf', str(quality),
               '-preset', 'medium', '-threads', str(threads), '-pix_fmt', 'yuv420p',
               '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-movflags', '+faststart',
               '-t', f'{duration:.9f}', str(temporary)]
    try:
        run(command, timeout=max(180, duration * 12))
        measured = probe(temporary)
        video = next(s for s in measured['streams'] if s['codec_type'] == 'video')
        audio = next(s for s in measured['streams'] if s['codec_type'] == 'audio')
        if (video['width'], video['height']) != (timeline['width'], timeline['height']):
            raise MediaError('Encoded movie dimensions differ from selected window resolution')
        tolerance = 1 / timeline['fps'] + 0.025
        if abs(float(measured['format']['duration']) - duration) > tolerance:
            raise MediaError('Encoded movie duration differs from its presentation timeline')
        if video['codec_name'] != 'h264' or audio['codec_name'] != 'aac':
            raise MediaError('Expected H.264 video and AAC narration')
        temporary.replace(movie)
    finally:
        temporary.unlink(missing_ok=True)
    first = next((frame for frame in frames if frame['pts_ns'] >= min(NS, timeline['duration_ns'] // 2)), frames[0])
    shutil.copyfile(asset(root, first['path']), render / 'poster.png')
    web = root / 'web'
    web.mkdir(exist_ok=True)
    for name in ('tutorial.mp4', 'poster.png', 'captions.vtt'):
        shutil.copyfile(render / name, web / name)
    html_player(root / 'standalone.html', timeline, movie, render / 'poster.png', render / 'captions.vtt')
    html_player(web / 'index.html', timeline, movie, render / 'poster.png', render / 'captions.vtt', standalone=False)
    # A small index maps useful images to final video time without renaming source captures.
    gallery = []
    for step in timeline['steps']:
        frame = next((f for f in reversed(frames) if f['pts_ns'] <= step['start_ns']), frames[0])
        gallery.append(dict(step=step['id'], video_time_ns=step['start_ns'], source=frame['path'],
                            filename=f't{step["start_ns"]:018d}ns_{slug(step["id"])}.png'))
    gallery_root = render / 'steps'
    gallery_root.mkdir(exist_ok=True)
    for image in gallery:
        destination = gallery_root / image['filename']
        if '/' in image['filename'] or '\\' in image['filename']:
            raise MediaError('Step identity is not filename-safe')
        shutil.copyfile(asset(root, image['source']), destination)
    write_json(render / 'images.json', gallery)
    version = run([encoder, '-version'], timeout=10).stdout.splitlines()[0]
    result = dict(schema=1, status='passed', duration_ns=timeline['duration_ns'], measured_duration=float(measured['format']['duration']),
                  width=timeline['width'], height=timeline['height'], frames=len(frames), steps=len(timeline['steps']),
                  lessons=len(timeline['lessons']), narration_clips=len(timeline['narration']), encoder=version,
                  video_sha256=digest(movie), video_bytes=movie.stat().st_size,
                  rendered_media_sha256=media_fingerprint(timeline),
                  standalone_bytes=(root / 'standalone.html').stat().st_size,
                  checks=['capture-integrity', 'timeline', 'audio-fit', 'video-dimensions', 'duration', 'codecs'],
                  browser_qualification='not yet run')
    write_json(root / 'validation.json', result)
    publication(root)
    print(f'Created {root / "standalone.html"}', flush=True)
    return result


def publication(root, player_url=None, video_url=None, poster_url=None):
    root = Path(root)
    folder = root / 'publication'
    folder.mkdir(exist_ok=True)
    # No upload or deployment occurs here. Placeholder URLs are deliberately obvious.
    player_url = player_url or 'REPLACE_WITH_PUBLISHED_PLAYER_URL'
    video_url = video_url or 'REPLACE_WITH_PUBLISHED_VIDEO_URL'
    poster_url = poster_url or 'REPLACE_WITH_PUBLISHED_POSTER_URL'
    (folder / 'README-snippet.md').write_text(
        f'[![Watch the narrated tutorial]({poster_url})]({player_url})\n\n'
        f'[Watch by chapter or step]({player_url}) · [Download the video]({video_url})\n\n'
        '<!-- Place this block before the project heading after publishing and verifying the URLs. -->\n')
    (folder / 'instructions.md').write_text(
        '# Publishing handoff\n\nThe recorder and compiler do not publish, commit, or push.\n\n'
        '1. Review the MP4, standalone HTML, captions, and validation report.\n'
        '2. Check current GitHub upload and Pages size limits against the actual files.\n'
        '3. Publish `web/` as a static site and select a movie location that supports seeking.\n'
        '4. Test the actual player, media, captions, step links, and download URLs.\n'
        '5. Regenerate the README snippet with those verified URLs and place it first in README.md.\n'
        '6. Upload standalone.html as a downloadable offline artifact.\n\n'
        'GitHub repository READMEs strip scripts; interactive step controls live on the HTML page.\n')
