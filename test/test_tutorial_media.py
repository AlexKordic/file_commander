"""Timing, integrity, image reconstruction, and portable HTML export contracts."""
import json
import math
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest
import wave
import zlib
from unittest.mock import patch

sys.dont_write_bytecode = True

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from tutorial_media.core import MediaError, NS, compile_timeline, digest, load_capture, subtitles, write_json, load_catalog
from tutorial_media.render import build, html_player, narration_track, probe
from tutorial_media.speech import pcm_duration, prepare, run
from tutorial_media.supervise import record, acquire_desktop
from tutorial_media.qualification import qualify, handoff


def png(path, rgb, width=200, height=100):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress((b'\0' + bytes(rgb) * width) * height)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def audio(path, seconds=.2):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as output:
        output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        output.writeframes(b''.join(struct.pack('<h', int(2000 * math.sin(i * 2 * math.pi * 440 / 48000))) for i in range(round(seconds * 48000))))


def fixture(root, identity='sample', width=200, height=100):
    take = root / 'capture' / identity
    take.mkdir(parents=True)
    frames = []
    for sequence, (at, color) in enumerate(((0, (230, 20, 20)), (600_000_000, (20, 20, 230)))):
        name = f'frames/frame_{at:018d}ns_20261109T100000000000Z_f{sequence:06d}_l-{identity}_s-test.png'
        png(take / name, color, width, height)
        frames.append(dict(pts_ns=at, sequence=sequence, path=name, sha256=digest(take / name)))
    events = []
    for n, (start, end) in enumerate(((0, 600_000_000), (600_000_000, 2 * NS))):
        segment = f'{identity}.step-{n}'
        events += [dict(type='segment_started', pts_ns=start, id=segment, title=f'Step {n}', text='Narrated step'),
                   dict(type='step_started', pts_ns=start, id=segment + '.action', action='caption'),
                   dict(type='step_completed', pts_ns=end, id=segment + '.action'),
                   dict(type='segment_completed', pts_ns=end, id=segment)]
    (take / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
    manifest = dict(schema=1, status='complete', width=width, height=height, fps=30, duration_ns=2 * NS, frames=frames,
                    lesson=dict(id=identity, title=identity, chapter='basics', chapter_title='Basics'), errors=[])
    write_json(take / 'manifest.json', manifest)
    return take


class TutorialMediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tutorial-media-')
        self.root = Path(self.temporary.name)
        self.take = fixture(self.root)
        write_json(self.root / 'course.json', dict(schema=1, title='Example tutorial', takes=[dict(manifest='capture/sample/manifest.json')]))

    def tearDown(self):
        self.temporary.cleanup()

    def change(self, transform):
        path = self.take / 'manifest.json'
        value = json.loads(path.read_text()); transform(value); write_json(path, value)

    def test_completed_take_and_raw_action_boundaries(self):
        timeline = compile_timeline(self.root)
        self.assertEqual(timeline['duration_ns'], 2 * NS)
        self.assertEqual([(s['start_ns'], s['end_ns']) for s in timeline['steps']], [(0, 600_000_000), (600_000_000, 2 * NS)])
        self.assertEqual(len(timeline['actions']), 2)
        self.assertIn('00:00:00.600 --> 00:00:02.000', subtitles(timeline))

    def test_incomplete_capture_is_not_publishable(self):
        self.change(lambda value: value.update(status='recording'))
        with self.assertRaisesRegex(MediaError, 'not a completed'):
            compile_timeline(self.root)

    def test_writer_errors_are_not_ignored(self):
        self.change(lambda value: value.update(errors=['Disk full']))
        with self.assertRaisesRegex(MediaError, 'Disk full'):
            compile_timeline(self.root)

    def test_modified_png_is_rejected(self):
        first = next((self.take / 'frames').glob('*.png'))
        first.write_bytes(first.read_bytes() + b'changed')
        with self.assertRaisesRegex(MediaError, 'checksum'):
            compile_timeline(self.root)

    def test_interrupted_png_cannot_be_accepted_with_a_new_file_hash(self):
        path = self.take / 'manifest.json'
        manifest = json.loads(path.read_text())
        frame = manifest['frames'][0]; image = self.take / frame['path']
        image.write_bytes(image.read_bytes()[:40]); frame['sha256'] = digest(image)
        write_json(path, manifest)
        with self.assertRaisesRegex(MediaError, 'Truncated PNG'):
            compile_timeline(self.root)

    def test_changed_native_frame_accounting_must_balance(self):
        self.change(lambda m: m.update(source_samples=4, coalesced_samples=1))
        self.change(lambda m: [f.update(source_timestamp=dict(value=f['pts_ns'], timescale=NS)) for f in m['frames']])
        with self.assertRaisesRegex(MediaError, 'Changed source frames were not saved'):
            compile_timeline(self.root)
        self.change(lambda m: m.update(source_samples=3))
        self.assertEqual(len(compile_timeline(self.root)['frames']), 2)

    @unittest.skipIf(sys.platform == 'win32', 'Native recording uses the macOS/Unix desktop lock')
    def test_native_capture_jobs_wait_for_desktop_focus_ownership(self):
        import subprocess
        import os
        import time
        child_root = self.root / 'second'; child_root.mkdir()
        ready = child_root / 'acquired'
        with patch('tutorial_media.supervise.tempfile.gettempdir', return_value=str(self.root)):
            first = acquire_desktop(self.root)
        code = ('import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); '
                'from tutorial_media.supervise import acquire_desktop; '
                'lock=acquire_desktop(Path(sys.argv[2])); Path(sys.argv[3]).write_text("owned"); lock.close()')
        child = subprocess.Popen([sys.executable, '-c', code, str(Path(__file__).resolve().parents[1] / 'tools'),
                                  str(child_root), str(ready)], env=dict(os.environ, TMPDIR=str(self.root), PYTHONDONTWRITEBYTECODE='1'),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (child_root / 'progress.json').exists():
                time.sleep(.02)
            self.assertTrue((child_root / 'progress.json').exists(), 'Second recording did not announce waiting')
            self.assertFalse(ready.exists(), 'Two native captures owned focus simultaneously')
            first.close()
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, stderr.decode())
            self.assertTrue(ready.exists())
        finally:
            first.close()
            if child.poll() is None:
                child.kill(); child.communicate(timeout=5)

    def test_frame_time_reversal_is_rejected(self):
        self.change(lambda value: value['frames'][1].update(pts_ns=0))
        with self.assertRaisesRegex(MediaError, 'increase strictly'):
            compile_timeline(self.root)

    def test_wall_clock_correction_does_not_retime_media(self):
        self.change(lambda value: value.update(clock=dict(origin_host_ns=123456789012345678,
                                                          anchor_utc_ns=1794247576000000000)))
        self.change(lambda value: [frame.update(utc=utc) for frame, utc in zip(value['frames'],
                      ['20261109T100001000000Z', '20261109T095959000000Z'])])
        timeline = compile_timeline(self.root)
        self.assertEqual([frame['pts_ns'] for frame in timeline['frames']], [0, 600_000_000])
        self.assertEqual(timeline['duration_ns'], 2 * NS)

    def test_incomplete_course_cannot_look_like_a_complete_subset(self):
        course = json.loads((self.root / 'course.json').read_text())
        course.update(status='complete', expected_lessons=['sample', 'missing'])
        write_json(self.root / 'course.json', course)
        with self.assertRaisesRegex(MediaError, 'missing requested lessons'):
            compile_timeline(self.root)

    def test_unfinished_presentation_is_rejected(self):
        events = self.take / 'events.jsonl'
        rows = [json.loads(row) for row in events.read_text().splitlines()]
        events.write_text(''.join(json.dumps(row) + '\n' for row in rows
                                 if not (row['type'] == 'segment_completed' and row['id'] == 'sample.step-1')))
        with self.assertRaisesRegex(MediaError, 'Unfinished presentation'):
            compile_timeline(self.root)

    def test_catalog_preserves_chapter_titles_and_rejects_duplicate_lessons(self):
        catalog = self.root / 'catalog.json'
        write_json(catalog, dict(schema=1, chapters=[dict(id='basics', title='Getting started')],
                                 lessons=[dict(id='sample', title='Sample')]))
        lessons, chapters = load_catalog(catalog)
        self.assertEqual(chapters[0]['title'], 'Getting started')
        write_json(catalog, lessons + lessons)
        with self.assertRaisesRegex(MediaError, 'unique'):
            load_catalog(catalog)

    def test_capture_permission_denial_stops_before_host_launch(self):
        binary = self.root / 'host'
        binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
        catalog = self.root / 'catalog.json'
        write_json(catalog, [dict(id='sample', title='Sample', steps=[])])
        with patch('tutorial_media.supervise.executable', return_value='encoder'), \
             patch('tutorial_media.supervise.subprocess.check_output', return_value='{"capture_permission":false}'), \
             patch('tutorial_media.supervise.subprocess.Popen') as spawn:
            with self.assertRaisesRegex(MediaError, 'Enable Screen Recording'):
                record(self.root / 'denied', binary, binary, catalog,
                       dict(x=0, y=0, pointsWidth=100, pointsHeight=100, scale=1), silent=True)
            spawn.assert_not_called()

    def test_asset_escape_is_rejected(self):
        self.change(lambda value: value['frames'][0].update(path='../../../outside.png'))
        with self.assertRaisesRegex(MediaError, 'escapes'):
            compile_timeline(self.root)

    def test_size_change_is_rejected(self):
        self.change(lambda value: value.update(width=202))
        with self.assertRaisesRegex(MediaError, 'geometry changed'):
            compile_timeline(self.root)

    def test_course_uses_measured_take_offsets(self):
        fixture(self.root, 'second')
        course = json.loads((self.root / 'course.json').read_text())
        course['takes'].append(dict(manifest='capture/second/manifest.json'))
        write_json(self.root / 'course.json', course)
        timeline = compile_timeline(self.root)
        self.assertEqual(timeline['duration_ns'], 4 * NS)
        self.assertEqual(timeline['steps'][2]['start_ns'], 2 * NS)
        self.assertEqual(timeline['frames'][2]['source_pts_ns'], 0)
        self.assertEqual(timeline['frames'][2]['pts_ns'], 2 * NS)

    def test_incomplete_action_cannot_be_hidden_by_finished_segment(self):
        events = self.take / 'events.jsonl'
        rows = [json.loads(row) for row in events.read_text().splitlines()]
        events.write_text(''.join(json.dumps(row) + '\n' for row in rows if row.get('id') != 'sample.step-1.action' or row['type'] != 'step_completed'))
        with self.assertRaisesRegex(MediaError, 'Unfinished actions'):
            compile_timeline(self.root)

    def test_speech_must_fit_its_visual_interval(self):
        clip = self.root / 'narration/clips/test.wav'; audio(clip, .8)
        write_json(self.root / 'narration/script.json', dict(schema=1, clips={'sample.step-0':dict(path='narration/clips/test.wav', sha256=digest(clip), duration_ns=800_000_000)}))
        with self.assertRaisesRegex(MediaError, 'does not fit'):
            compile_timeline(self.root)

    def test_narration_silence_and_placement(self):
        clip = self.root / 'clip.wav'; audio(clip)
        timeline = dict(duration_ns=2 * NS, narration=[dict(id='test', path='clip.wav', duration_ns=200_000_000, start_ns=NS)])
        output = self.root / 'track.wav'; narration_track(self.root, timeline, output)
        with wave.open(str(output), 'rb') as result:
            self.assertEqual(result.getnframes(), 96000)
            self.assertEqual(set(result.readframes(48000)), {0})
            self.assertGreater(len(set(result.readframes(9600))), 1)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg is the integration dependency')
    def test_video_reconstruction_keeps_final_image_and_offline_player(self):
        result = build(self.root, threads=1)
        self.assertEqual(result['status'], 'passed')
        self.assertLess(abs(result['measured_duration'] - 2), 1 / 30 + .025)
        # Inspect the last delivered picture: failure to retain the final hold
        # makes this red or makes the movie end before this seek succeeds.
        import subprocess
        pixels = subprocess.check_output([shutil.which('ffmpeg'), '-v', 'error', '-ss', '1.8', '-i', str(self.root / 'render/tutorial.mp4'),
                                          '-frames:v', '1', '-vf', 'scale=1:1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
        self.assertEqual(len(pixels), 3)
        self.assertGreater(pixels[2], pixels[0] + 100)
        page = (self.root / 'standalone.html').read_text()
        self.assertNotIn('__MOVIE__', page)
        self.assertIn('requestVideoFrameCallback', page)
        self.assertIn('Play this step', page)
        self.assertNotIn('<script src=', page)
        self.assertTrue((self.root / 'web/tutorial.mp4').is_file())
        self.assertTrue((self.root / 'publication/README-snippet.md').is_file())
        qualified = qualify(self.root)
        self.assertTrue(qualified['all_packets_decoded'])
        (self.root / 'profile').mkdir(); (self.root / 'profile/private').write_text('not a media source')
        delivery = handoff(self.root)
        import tarfile
        with tempfile.TemporaryDirectory() as extracted:
            with tarfile.open(delivery / 'capture-source.tar.gz') as archive:
                self.assertFalse(any('profile' in name or 'host.log' in name for name in archive.getnames()))
                archive.extractall(extracted, filter='data')
            self.assertEqual(compile_timeline(extracted)['duration_ns'], 2 * NS)
        self.change(lambda m: m.update(duration_ns=3 * NS))
        with self.assertRaisesRegex(MediaError, 'Source media changed'):
            qualify(self.root)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg normalizes imported audio')
    def test_imported_speech_cache_and_text_invalidation(self):
        imported = self.root / 'imported'; audio(imported / 'example.caption.wav')
        catalog = self.root / 'catalog.json'
        lesson = dict(id='example', title='Example', steps=[dict(caption='Hello', id='action', presentation=dict(id='example.caption', title='Hello', narration='Hello from another host.'))])
        write_json(catalog, [lesson])
        first = prepare(catalog, self.root, imported=imported)
        clip = self.root / first['clips']['example.caption']['path']; before = clip.stat().st_mtime_ns
        second = prepare(catalog, self.root, imported=imported)
        self.assertEqual(before, clip.stat().st_mtime_ns)
        lesson['steps'][0]['presentation']['narration'] = 'Changed narration.'; write_json(catalog, [lesson])
        third = prepare(catalog, self.root, imported=imported)
        self.assertNotEqual(first['clips']['example.caption']['cache_key'], third['clips']['example.caption']['cache_key'])

    def test_html_does_not_execute_lesson_text(self):
        timeline = compile_timeline(self.root)
        timeline['title'] = '</title><script>alert(1)</script>'
        timeline['steps'][0]['text'] = '</script><script>bad()</script>'
        movie = self.root / 'example.mp4'; movie.write_bytes(b'example')
        poster = next((self.take / 'frames').glob('*.png'))
        captions = self.root / 'captions.vtt'; captions.write_text(subtitles(timeline))
        output = self.root / 'page.html'; html_player(output, timeline, movie, poster, captions)
        page = output.read_text()
        self.assertNotIn('</script><script>bad()', page)
        self.assertNotIn('</title><script>alert', page)


if __name__ == '__main__':
    unittest.main()
