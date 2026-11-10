"""Additional H.264 export that preserves retained-image presentation times."""
from __future__ import annotations

from fractions import Fraction
import json
import math
from pathlib import Path
import tempfile

from .core import MediaError, NS, asset, compile_timeline, digest, media_fingerprint, write_json
from .render import chapter_metadata, ffquote, narration_track, probe
from .speech import executable, run

TIMESCALE = 90_000


def validate_options(crf, threads):
    if isinstance(crf, bool) or not isinstance(crf, (int, float)) or not math.isfinite(crf) or not 0 <= crf <= 51:
        raise MediaError('VFR CRF must be a finite number from 0 to 51 (lower means higher quality)')
    if isinstance(threads, bool) or not isinstance(threads, int) or not 1 <= threads <= 32:
        raise MediaError('Encoder threads must be 1–32')


def image_timing(timeline):
    # Round absolute timestamps once, then subtract. Rounding every interval
    # independently would accumulate drift over thousands of images.
    points = [(frame['pts_ns'] * TIMESCALE + NS // 2) // NS for frame in timeline['frames']]
    end = (timeline['duration_ns'] * TIMESCALE + NS // 2) // NS
    durations = [right - left for left, right in zip(points, points[1:] + [end])]
    if not points or points[0] != 0 or any(duration <= 0 for duration in durations):
        raise MediaError('VFR image timestamps must remain distinct at 1/90000-second precision')
    return points, durations, end


def image_playlist(root, timeline, points, end):
    # ffconcat parses durations in microseconds, even when the PNG stream has a
    # 90 kHz time base. Convert rounded absolute ticks to that transport clock
    # before subtracting. Each input PTS then rescales back to the intended tick,
    # without accumulating the per-interval decimal/microsecond rounding error.
    micros = [(point * 1_000_000 + TIMESCALE // 2) // TIMESCALE for point in points + [end]]
    durations = [right - left for left, right in zip(micros, micros[1:])]
    rows = ['ffconcat version 1.0']
    for frame, duration in zip(timeline['frames'], durations):
        rows += ['file ' + ffquote(asset(root, frame['path'])), f'option framerate {TIMESCALE}',
                 f'duration {duration // 1_000_000}.{duration % 1_000_000:06d}']
    # No duplicate final image: its packet gets the measured final hold below.
    return '\n'.join(rows) + '\n'


def encoding_command(encoder, folder, movie, timeline, points, durations, end, crf, threads):
    return [encoder, '-v', 'warning', '-xerror', '-nostdin', '-y', '-err_detect', 'explode',
            '-f', 'concat', '-safe', '0', '-i', str(folder / 'frames-vfr.ffconcat'),
            '-i', str(folder / 'narration-vfr.wav'), '-i', str(folder / 'chapters-vfr.ffmetadata'),
            '-map', '0:v:0', '-map', '1:a:0', '-map_metadata', '2',
            '-c:v', 'libx264', '-crf', str(crf), '-preset', 'medium', '-threads', str(threads),
            '-pix_fmt', 'yuv420p', '-fps_mode:v', 'vfr', '-enc_time_base:v', f'1:{TIMESCALE}',
            '-video_track_timescale', str(TIMESCALE),
            # The PNG demuxer's 90 kHz clock is not a 90,000-fps video.
            # Set x264's nominal rate separately, without an FFmpeg -r/fps filter.
            '-x264-params', f'fps={timeline["fps"]}/1:force-cfr=0',
            # Avoid reordered DTS shortening sparse holds in MP4. Every packet
            # corresponds to exactly one retained image, in presentation order.
            '-bf', '0', '-bsf:v', f"setts=duration='if(eq(PTS,{points[-1]}),{durations[-1]},DURATION)'",
            '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-movflags', '+faststart',
            '-t', f'{end / TIMESCALE:.9f}', str(movie)]


def verify_movie(movie, timeline, points, durations, end):
    info = probe(movie)
    video = next((s for s in info['streams'] if s['codec_type'] == 'video'), {})
    audio = next((s for s in info['streams'] if s['codec_type'] == 'audio'), {})
    if video.get('codec_name') != 'h264' or audio.get('codec_name') != 'aac':
        raise MediaError('VFR export requires H.264 video and AAC audio')
    if (video['width'], video['height']) != (timeline['width'], timeline['height']):
        raise MediaError('VFR movie dimensions differ from source images')
    if Fraction(video['time_base']) != Fraction(1, TIMESCALE):
        raise MediaError('VFR movie lost its 1/90000-second time base')
    packets = json.loads(run([executable('ffprobe'), '-v', 'error', '-select_streams', 'v:0',
                             '-show_packets', '-show_entries', 'packet=pts,dts,duration',
                             '-of', 'json', str(movie)], timeout=60).stdout)['packets']
    if len(packets) != len(points):
        raise MediaError(f'VFR image accounting failed: {len(points)} images, {len(packets)} packets')
    for index, (packet, at, duration) in enumerate(zip(packets, points, durations)):
        if packet.get('pts') != at or packet.get('dts') != at or packet.get('duration') != duration:
            raise MediaError(f'VFR frame {index} does not preserve its recorded presentation interval')
    if video.get('duration_ts') != end:
        raise MediaError('VFR video stream does not preserve its final image hold')
    if abs(float(audio.get('duration', 0)) - end / TIMESCALE) > 1024 / 48000 + .001:
        raise MediaError('VFR audio duration differs from its presentation timeline')
    run([executable('ffmpeg'), '-v', 'error', '-xerror', '-nostdin', '-err_detect', 'explode',
         '-i', str(movie), '-map', '0:v:0', '-map', '0:a:0', '-fps_mode:v', 'passthrough',
         '-f', 'null', '-'], timeout=max(180, end / TIMESCALE * 3))
    return info


def build_vfr(root, crf=18, threads=4):
    """Write only VFR artifacts; never rebuild the primary movie or player."""
    validate_options(crf, threads)
    root = Path(root).resolve()
    timeline = compile_timeline(root)
    points, durations, end = image_timing(timeline)
    playlist = image_playlist(root, timeline, points, end)
    encoder = executable('ffmpeg')
    render = root / 'render'
    render.mkdir(exist_ok=True)
    movie = render / 'tutorial-vfr.mp4'
    print(f'Encoding VFR: {len(points)} images at {timeline["width"]}×{timeline["height"]}, '
          f'{end / TIMESCALE:.2f}s, CRF {crf:g}', flush=True)
    # Keep an earlier successful VFR export until its replacement is verified.
    # All work files are private, including audio, so existing CFR inputs and
    # concurrent VFR encodes cannot be changed underneath the encoder.
    with tempfile.TemporaryDirectory(prefix='.vfr-', dir=render) as scratch:
        stage = Path(scratch)
        (stage / 'frames-vfr.ffconcat').write_text(playlist)
        narration_track(root, timeline, stage / 'narration-vfr.wav')
        (stage / 'chapters-vfr.ffmetadata').write_text(chapter_metadata(timeline))
        temporary = stage / movie.name
        command = encoding_command(encoder, stage, temporary, timeline, points, durations, end, crf, threads)
        run(command, timeout=max(180, end / TIMESCALE * 12))
        measured = verify_movie(temporary, timeline, points, durations, end)
        result = dict(schema=1, status='passed', timing='vfr', crf=crf, preset='medium',
                      duration_ns=timeline['duration_ns'], video_duration_ticks=end,
                      measured_duration=float(measured['format']['duration']),
                      width=timeline['width'], height=timeline['height'], frames=len(points),
                      lessons=len(timeline['lessons']), steps=len(timeline['steps']),
                      time_base=f'1/{TIMESCALE}', max_timestamp_rounding_ns=math.ceil(NS / (2 * TIMESCALE)),
                      min_frame_duration_ticks=min(durations), max_frame_duration_ticks=max(durations),
                      all_packets_decoded=True, source_frame_accounting='passed',
                      video_sha256=digest(temporary), video_bytes=temporary.stat().st_size,
                      rendered_media_sha256=media_fingerprint(timeline),
                      encoder=run([encoder, '-version'], timeout=10).stdout.splitlines()[0],
                      encode_command=encoding_command(encoder, render, movie, timeline, points, durations, end, crf, threads),
                      checks=['capture-integrity', 'one-packet-per-image', 'recorded-timestamps',
                              'frame-durations', 'final-image-hold', 'audio-duration', 'full-decode'],
                      browser_qualification='not yet run')
        for name in ('frames-vfr.ffconcat', 'narration-vfr.wav', 'chapters-vfr.ffmetadata', movie.name):
            (stage / name).replace(render / name)
    write_json(root / 'validation-vfr.json', result)
    print(f'Created {movie} ({result["video_bytes"] / 1_000_000:.2f} MB); '
          'recorded images and primary exports unchanged', flush=True)
    return result
