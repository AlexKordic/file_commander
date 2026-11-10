"""Command-line entry point; deliberately has no publishing operation."""
import argparse
import json
import sys
import signal
from pathlib import Path

from .core import MediaError, compile_timeline, write_json
from .render import build, publication
from .speech import prepare
from .supervise import record
from .qualification import qualify, handoff
from .vfr import build_vfr, validate_options as validate_vfr_options


def main(argv=None):
    def cancelled(_signal, _frame):
        raise KeyboardInterrupt('Recording cancelled')
    signal.signal(signal.SIGTERM, cancelled)
    parser = argparse.ArgumentParser(description='Build timestamped tutorial captures into narrated offline HTML and MP4')
    commands = parser.add_subparsers(dest='command', required=True)
    speech = commands.add_parser('prepare', help='Generate or import narration before recording')
    speech.add_argument('--catalog', type=Path, required=True)
    speech.add_argument('--out', type=Path, required=True)
    speech.add_argument('--lessons', help='Comma-separated lesson IDs; default: all')
    speech.add_argument('--voice')
    speech.add_argument('--language', default='en', help='Voice language, for example en or en-US')
    speech.add_argument('--rate', type=int, default=180)
    speech.add_argument('--import-audio', type=Path)
    render = commands.add_parser('build', help='Reconstruct video and generate standalone/hosted players')
    render.add_argument('root', type=Path)
    render.add_argument('--quality', type=int, default=18)
    render.add_argument('--threads', type=int, default=4)
    render.add_argument('--title')
    render.add_argument('--also-vfr', action='store_true', help='Also encode render/tutorial-vfr.mp4 from image timing')
    render.add_argument('--vfr-crf', type=float, help='Quality of the additional VFR video; default: --quality')
    vfr = commands.add_parser('vfr', help='Encode only an additional VFR movie; preserve existing movies, players and images')
    vfr.add_argument('root', type=Path)
    vfr.add_argument('--vfr-crf', type=float, default=18, help='x264 constant quality, 0–51; lower is higher quality (default: 18)')
    vfr.add_argument('--threads', type=int, default=4)
    validate = commands.add_parser('validate', help='Validate complete captures and final timing without rendering')
    validate.add_argument('root', type=Path)
    qualification = commands.add_parser('qualify', help='Decode all media and measure early/middle/late audio alignment')
    qualification.add_argument('root', type=Path)
    qualification.add_argument('--browser-report', type=Path)
    delivery = commands.add_parser('handoff', help='Prepare a source archive and local deliverables; never publishes')
    delivery.add_argument('root', type=Path)
    capture = commands.add_parser('record', help='Record isolated tutorial hosts, including restart lessons')
    capture.add_argument('--app', type=Path, required=True)
    capture.add_argument('--capture-bin', type=Path, required=True)
    capture.add_argument('--catalog', type=Path, required=True)
    capture.add_argument('--out', type=Path, required=True)
    capture.add_argument('--geometry', required=True, help='JSON geometry or a path to its JSON file')
    capture.add_argument('--lessons')
    capture.add_argument('--voice')
    capture.add_argument('--language', default='en')
    capture.add_argument('--rate', type=int, default=180)
    capture.add_argument('--fps', type=int, default=30)
    capture.add_argument('--appearance', choices=('system', 'light', 'dark'), default='system')
    capture.add_argument('--host-options', help='Host presentation options as a JSON object or a JSON file')
    capture.add_argument('--title', default='Tutorial')
    capture.add_argument('--import-audio', type=Path)
    capture.add_argument('--silent', action='store_true')
    capture.add_argument('--resume', action='store_true')
    capture.add_argument('--retake', help='With --resume, re-record these comma-separated lesson IDs and retain the others')
    capture.add_argument('--capture-only', action='store_true')
    publish = commands.add_parser('publication', help='Prepare a README snippet; never uploads or publishes')
    publish.add_argument('root', type=Path)
    publish.add_argument('--player-url', required=True)
    publish.add_argument('--video-url', required=True)
    publish.add_argument('--poster-url', required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'prepare':
            prepare(args.catalog, args.out, args.lessons.split(',') if args.lessons else None,
                    args.voice, args.rate, args.import_audio, args.language)
        elif args.command == 'build':
            if not 0 <= args.quality <= 35 or not 1 <= args.threads <= 32:
                raise MediaError('Quality must be 0–35 and encoder threads 1–32')
            if args.vfr_crf is not None and not args.also_vfr:
                raise MediaError('--vfr-crf requires --also-vfr; use the vfr command to preserve existing exports')
            if args.also_vfr:
                crf = args.vfr_crf if args.vfr_crf is not None else args.quality
                validate_vfr_options(crf, args.threads)
            build(args.root, args.quality, args.threads, args.title)
            if args.also_vfr:
                build_vfr(args.root, crf, args.threads)
        elif args.command == 'vfr':
            build_vfr(args.root, args.vfr_crf, args.threads)
        elif args.command == 'validate':
            timeline = compile_timeline(args.root)
            print(json.dumps({key: timeline[key] for key in ('schema', 'title', 'width', 'height', 'duration_ns')}))
        elif args.command == 'record':
            geometry = (json.loads(args.geometry) if args.geometry.lstrip().startswith('{') else
                        json.loads(Path(args.geometry).read_text()))
            record(args.out, args.app, args.capture_bin, args.catalog, geometry,
                   args.lessons.split(',') if args.lessons else None, args.voice, args.rate,
                   args.import_audio, args.fps, args.silent, args.resume, not args.capture_only, args.appearance, args.title, args.language,
                   args.retake.split(',') if args.retake else None,
                   (json.loads(args.host_options) if args.host_options.lstrip().startswith('{') else
                    json.loads(Path(args.host_options).read_text())) if args.host_options else None)
        elif args.command == 'qualify':
            print(json.dumps(qualify(args.root, args.browser_report), indent=2))
        elif args.command == 'handoff':
            print(handoff(args.root))
        elif args.command == 'publication':
            publication(args.root, args.player_url, args.video_url, args.poster_url)
    except (MediaError, OSError, KeyError, ValueError) as error:
        parser.exit(1, f'Tutorial media: {error}\n')
    except KeyboardInterrupt:
        parser.exit(130, 'Tutorial recording cancelled; captured images were retained.\n')
