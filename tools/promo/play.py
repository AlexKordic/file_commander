#!/usr/bin/env python3
"""Play the promo storyboard: drive a real FC session through scripted scenes.

FC runs in a pseudo-terminal. Its output is mirrored to this terminal so a
screen recorder can capture it, while the player types keys, clicks, waits for
text on screen and restarts FC. Captions, highlights and pointer moves are
written as JSON lines for the overlay app, and captions also as an .srt file.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import random
import re
import select
import signal
import struct
import sys
import termios
import time
import tty

try:
    import pyte
except ImportError:
    raise SystemExit('pyte is missing: python3 -m venv build-promo/venv && build-promo/venv/bin/pip install -r tools/promo/requirements.txt')

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

KEYS = {
    'Enter': b'\r', 'Tab': b'\t', 'Esc': b'\x1b', 'Space': b' ', 'Backspace': b'\x7f', 'Delete': b'\x1b[3~',
    'Up': b'\x1b[A', 'Down': b'\x1b[B', 'Right': b'\x1b[C', 'Left': b'\x1b[D', 'Home': b'\x1b[H', 'End': b'\x1b[F',
    'PageUp': b'\x1b[5~', 'PageDown': b'\x1b[6~', 'Ctrl+Right': b'\x1b[1;5C', 'Ctrl+Left': b'\x1b[1;5D', 'Ctrl+Home': b'\x1b[1;5H', 'Ctrl+End': b'\x1b[1;5F',
    'F1': b'\x1bOP', 'F2': b'\x1bOQ', 'F3': b'\x1bOR', 'F4': b'\x1bOS', 'F5': b'\x1b[15~', 'F6': b'\x1b[17~',
    'F7': b'\x1b[18~', 'F8': b'\x1b[19~', 'F9': b'\x1b[20~', 'F10': b'\x1b[21~', 'F11': b'\x1b[23~', 'F12': b'\x1b[24~',
}
KEYS.update({f'Ctrl+{c}': bytes([ord(c) - 64]) for c in 'ABCDEFGHIJKLNOPQRSTUVWXYZ'})
STEP_KINDS = {'clear', 'shell', 'launch', 'wait', 'wait_gone', 'keys', 'type', 'pause', 'caption', 'uncaption',
              'highlight', 'point', 'click', 'crash', 'quit', 'print'}
# Restores the terminal after FC is killed: mouse modes off, cursor on, main screen.
TERMINAL_RESET = b'\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1015l\x1b[?2004l\x1b[?25h\x1b[?1049l\x1b[0m'


class StoryError(Exception):
    pass


def validate(story):
    seen = set()
    for scene in story['scenes']:
        if scene['id'] in seen:
            raise StoryError(f"duplicate scene id {scene['id']}")
        seen.add(scene['id'])
        for index, step in enumerate(scene['steps']):
            kinds = STEP_KINDS & step.keys()
            where = f"{scene['id']} step {index + 1}"
            if len(kinds) != 1:
                raise StoryError(f'{where}: expected exactly one of {sorted(STEP_KINDS)}, got {sorted(step)}')
            for key in step.get('keys', []) + step.get('fallback', []):
                if key not in KEYS and len(key) != 1:
                    raise StoryError(f'{where}: unknown key {key!r}')
            for pattern in (step.get('wait'), step.get('wait_gone'), *(step.get(k, {}).get('text') for k in ('highlight', 'point', 'click'))):
                if isinstance(pattern, str):
                    re.compile(pattern)
    return seen


class Events:
    """Overlay event stream (JSON lines) and caption subtitles."""

    def __init__(self, path, srt):
        self.start = time.monotonic()
        self.stream = None
        if path and path.startswith('unix:'):
            import socket
            self.stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.stream.connect(path[5:])
            self.stream = self.stream.makefile('w', buffering=1)
        elif path:
            self.stream = open(path, 'w', buffering=1)
        self.srt, self.cues, self.open_cue = srt, [], None

    def now(self):
        return time.monotonic() - self.start

    def emit(self, event, **fields):
        if self.stream:
            self.stream.write(json.dumps({'t': round(self.now(), 3), 'event': event, **fields}) + '\n')

    def caption(self, text, sub):
        self.uncaption()
        self.open_cue = [self.now(), None, text + (f'\n{sub}' if sub else '')]
        self.emit('caption', text=text, sub=sub)

    def uncaption(self):
        if self.open_cue:
            self.open_cue[1] = self.now()
            self.cues.append(self.open_cue)
            self.open_cue = None
            self.emit('uncaption')

    def close(self):
        self.uncaption()
        if self.srt:
            def stamp(seconds):
                ms = int(seconds * 1000)
                return f'{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}'
            with open(self.srt, 'w') as out:
                for number, (begin, end, text) in enumerate(self.cues, 1):
                    out.write(f'{number}\n{stamp(begin)} --> {stamp(end)}\n{text}\n\n')
        if self.stream:
            self.emit('end')
            self.stream.close()


class Player:
    def __init__(self, story, args, world):
        self.story, self.args, self.world = story, args, world
        self.mirror = not args.headless
        pace = story.get('pace', {})
        self.key_gap = pace.get('key_gap_ms', 450)
        self.type_ms = pace.get('type_ms', [60, 130])
        self.random = random.Random(pace.get('seed', 1))
        self.events = Events(args.events, args.srt)
        self.cols, self.rows = self.terminal_size()
        self.pid = self.fd = None
        self.screen = pyte.Screen(self.cols, self.rows)
        self.stream = pyte.ByteStream(self.screen)
        self.stdin_buffer = b''
        self.saved_tty = None

    # -- terminal -----------------------------------------------------------
    def terminal_size(self):
        need = self.story.get('terminal', {})
        if self.mirror:
            size = os.get_terminal_size(sys.stdout.fileno())
            cols, rows = size.columns, size.lines
        else:
            cols, rows = (int(v) for v in self.args.size.split('x'))
        if cols < need.get('min_cols', 0) or rows < need.get('min_rows', 0):
            raise StoryError(f"terminal is {cols}x{rows}; the storyboard needs at least {need['min_cols']}x{need['min_rows']}")
        return cols, rows

    def out(self, data):
        if self.mirror:
            os.write(sys.stdout.fileno(), data)

    def sleep(self, ms):
        self.pump(ms / 1000 / self.args.speed)

    def pump(self, seconds):
        """Mirror FC output and forward terminal replies for up to `seconds`."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            fds = ([self.fd] if self.fd is not None else []) + ([sys.stdin.fileno()] if self.mirror else [])
            if not fds:
                time.sleep(max(remaining, 0))
                return
            ready, _, _ = select.select(fds, [], [], max(remaining, 0))
            if self.fd is not None and self.fd in ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    data = b''
                if not data:
                    self.reap()
                else:
                    self.out(data)
                    self.stream.feed(data)
                    if not self.mirror and b'\x1b[6n' in data:
                        os.write(self.fd, f'\x1b[{self.screen.cursor.y + 1};{self.screen.cursor.x + 1}R'.encode())
            if self.mirror and sys.stdin.fileno() in ready:
                self.forward_stdin(os.read(sys.stdin.fileno(), 4096))
            if remaining <= 0:
                return

    def forward_stdin(self, data):
        """Pass the real terminal's replies to FC; drop keyboard and mouse input. Ctrl+\\ aborts."""
        if b'\x1c' in data:
            raise KeyboardInterrupt
        self.stdin_buffer += data
        reply = re.compile(rb'\x1b\[[?>]?[\d;]*[Rcyn$t]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1bP.*?\x1b\\', re.S)
        while self.stdin_buffer:
            match = reply.match(self.stdin_buffer)
            if match:
                if self.fd is not None:
                    os.write(self.fd, match.group())
                self.stdin_buffer = self.stdin_buffer[match.end():]
            elif self.stdin_buffer.startswith(b'\x1b') and len(self.stdin_buffer) < 64 and not re.match(rb'\x1b\[<[\d;]*[Mm]', self.stdin_buffer):
                return  # Possibly an incomplete reply; wait for more bytes.
            else:
                mouse = re.match(rb'\x1b\[<[\d;]*[Mm]', self.stdin_buffer)
                self.stdin_buffer = self.stdin_buffer[mouse.end() if mouse else 1:]

    # -- FC process ---------------------------------------------------------
    def environment(self):
        env = dict(os.environ, HOME=self.world['profile'], XDG_CONFIG_HOME=self.world['config'],
                   FRESH_SESSION_IDLE_TIMEOUT_SECS='120')
        env.setdefault('TERM', 'xterm-256color')
        env.setdefault('LANG', 'en_US.UTF-8')
        return env

    def launch(self, spec):
        if self.pid is not None:
            raise StoryError('FC is already running')
        args = [self.expand(a) for a in spec.get('args', [])]
        self.screen = pyte.Screen(self.cols, self.rows)
        self.stream = pyte.ByteStream(self.screen)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.world['home'])
            os.execve(self.args.fc, [self.args.fc, *args], self.environment())
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', self.rows, self.cols, 0, 0))
        self.pid, self.fd = pid, fd
        self.events.emit('launch', cols=self.cols, rows=self.rows)

    def reap(self):
        if self.pid is not None:
            os.waitpid(self.pid, 0)
            os.close(self.fd)
            self.pid = self.fd = None

    def crash(self, spec):
        self.events.emit('crash')
        os.kill(self.pid, signal.SIGKILL)
        self.reap()
        self.out(TERMINAL_RESET)
        if spec.get('message'):
            self.out(f"\r\n{spec['message']}\r\n".encode())

    def quit(self):
        if self.pid is None:
            return
        os.write(self.fd, b'\x03')
        deadline = time.monotonic() + 10
        while self.pid is not None and time.monotonic() < deadline:
            self.pump(0.1)
        if self.pid is not None:
            raise StoryError('FC did not exit after Ctrl+C')

    # -- screen queries -----------------------------------------------------
    def lines(self):
        rows = []
        for row in range(self.rows):
            text, columns = '', []
            line = self.screen.buffer[row]
            for col in range(self.cols):
                char = line[col].data
                if char:
                    text += char
                    columns.extend([col] * len(char))
            rows.append((text, columns))
        return rows

    def text(self):
        return '\n'.join(text for text, _ in self.lines())

    def find(self, target):
        """Cell rectangle of the nth regex match, optionally limited to one half of the screen."""
        pattern, half, wanted = re.compile(self.expand(target['text'])), target.get('half'), target.get('nth', 0)
        found = []
        for row, (text, columns) in enumerate(self.lines()):
            for match in pattern.finditer(text):
                if match.end() == match.start():
                    continue
                col = columns[match.start()]
                if half == 'left' and col >= self.cols // 2 or half == 'right' and col < self.cols // 2:
                    continue
                found.append({'row': row, 'col': col, 'rows': 1, 'cols': columns[match.end() - 1] - col + 1})
        if len(found) <= wanted:
            raise StoryError(f"target {target} not on screen")
        return found[wanted]

    def wait(self, pattern, timeout, present=True):
        regex, deadline = re.compile(pattern), time.monotonic() + timeout
        while bool(regex.search(self.text())) != present:
            if time.monotonic() > deadline:
                raise StoryError(f"timed out after {timeout}s waiting for {'' if present else 'no '}{pattern!r}")
            if self.pid is None:
                raise StoryError(f'FC exited while waiting for {pattern!r}')
            self.pump(0.05)

    # -- steps --------------------------------------------------------------
    def expand(self, value):
        return (value.replace('{home}', self.world['home']).replace('{server}', self.world['server'])
                .replace('{ssh_host}', self.world['ssh_host']))

    def send(self, data):
        if self.fd is None:
            raise StoryError('FC is not running')
        os.write(self.fd, data)

    def type_chars(self, text, to_fc=True):
        for char in text:
            (self.send if to_fc else self.out)(char.encode())
            self.sleep(self.random.randint(*self.type_ms))

    def run_step(self, step):
        timeout = step.get('timeout', 15)
        if 'clear' in step:
            self.out(b'\x1b[2J\x1b[H')
        elif 'shell' in step:
            self.out(self.story.get('prompt', '$ ').encode())
            self.sleep(500)
            self.type_chars(self.expand(step['shell']), to_fc=False)
            self.sleep(350)
            self.out(b'\r\n')
        elif 'print' in step:
            self.out(step['print'].replace('\n', '\r\n').encode())
        elif 'launch' in step:
            self.launch(step['launch'])
        elif 'wait' in step:
            try:
                self.wait(self.expand(step['wait']), timeout)
            except StoryError:
                # Recover where a slower path is acceptable, such as refreshing a
                # panel when the platform's file watcher is unavailable.
                if 'fallback' not in step:
                    raise
                self.run_step({'keys': step['fallback']})
                self.wait(self.expand(step['wait']), timeout)
        elif 'wait_gone' in step:
            self.wait(self.expand(step['wait_gone']), timeout, present=False)
        elif 'keys' in step:
            for key in step['keys']:
                self.events.emit('key', label=key)
                self.send(KEYS.get(key, key.encode()))
                self.sleep(step.get('gap', self.key_gap))
        elif 'type' in step:
            self.events.emit('type', text=step['type'])
            self.type_chars(self.expand(step['type']))
        elif 'pause' in step:
            self.sleep(step['pause'])
        elif 'caption' in step:
            self.events.caption(step['caption'], step.get('sub', ''))
        elif 'uncaption' in step:
            self.events.uncaption()
        elif 'highlight' in step:
            self.events.emit('highlight', rect=self.find(step['highlight']), style=step['highlight'].get('style', 'box'),
                             label=step['highlight'].get('label', ''))
        elif 'point' in step or 'click' in step:
            target = step.get('point') or step.get('click')
            rect, duration = self.find(target), target.get('ms', 700)
            self.events.emit('pointer', rect=rect, ms=duration, click='click' in step)
            self.sleep(duration)
            if 'click' in step:
                x, y = rect['col'] + rect['cols'] // 2 + 1, rect['row'] + 1
                self.send(f'\x1b[<0;{x};{y}M'.encode())
                self.sleep(90)
                self.send(f'\x1b[<0;{x};{y}m'.encode())
        elif 'crash' in step:
            self.crash(step['crash'])
        elif 'quit' in step:
            self.quit()
        if step.get('hold'):
            self.sleep(step['hold'])

    def play(self, skip):
        timings = []
        self.events.emit('start', cols=self.cols, rows=self.rows, title=self.story.get('title', ''))
        for number, scene in enumerate(self.story['scenes'], 1):
            if scene['id'] in skip:
                continue
            began = self.events.now()
            self.events.emit('scene', id=scene['id'], title=scene.get('title', ''))
            for index, step in enumerate(scene['steps'], 1):
                try:
                    self.run_step(step)
                except StoryError as error:
                    raise StoryError(f"scene {scene['id']}, step {index} {json.dumps(step)}: {error}") from None
            if self.args.screens:
                self.args.screens.mkdir(parents=True, exist_ok=True)
                (self.args.screens / f"{number:02}-{scene['id']}.txt").write_text(self.text() + '\n')
            timings.append((scene['id'], self.events.now() - began))
        return timings

    def __enter__(self):
        if self.mirror:
            self.saved_tty = termios.tcgetattr(sys.stdin.fileno())
            tty.setraw(sys.stdin.fileno())
        return self

    def __exit__(self, *error):
        if self.pid is not None:
            os.kill(self.pid, signal.SIGKILL)
            self.reap()
            self.out(TERMINAL_RESET)
        if self.saved_tty:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self.saved_tty)
        self.events.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--story', type=Path, default=HERE / 'storyboard.json')
    parser.add_argument('--root', type=Path, default=Path('/tmp/fc-promo'), help='world built by make_world.py')
    parser.add_argument('--fc', default=str(REPO / 'build-release' / 'fc'))
    parser.add_argument('--skip', action='append', default=[], help='scene id to leave out (repeatable)')
    parser.add_argument('--events', help='overlay event stream: a file path or unix:/path/to/socket')
    parser.add_argument('--srt', help='write captions as subtitles to this .srt file')
    parser.add_argument('--headless', action='store_true', help='rehearse without mirroring to this terminal')
    parser.add_argument('--size', default='120x34', help='terminal size for --headless, COLSxROWS')
    parser.add_argument('--speed', type=float, default=1.0, help='divide pauses and typing delays by this factor')
    parser.add_argument('--screens', type=Path, help='save a text screenshot at the end of each scene')
    parser.add_argument('--check', action='store_true', help='validate the storyboard and exit')
    args = parser.parse_args()

    story = json.loads(args.story.read_text())
    ids = validate(story)
    unknown = set(args.skip) - ids
    if unknown:
        raise SystemExit(f'unknown scene ids: {sorted(unknown)}')
    if args.check:
        print(f"{args.story.name}: {len(story['scenes'])} scenes OK")
        return
    marker = args.root / '.fc-promo-world'
    if not marker.is_file():
        raise SystemExit(f'{args.root} is not a promo world; run tools/promo/make_world.py first')
    world = json.loads(marker.read_text())

    failure = None
    try:
        with Player(story, args, world) as player:
            timings = player.play(set(args.skip))
    except StoryError as error:
        failure = error
        screen = player.text() if 'player' in locals() else ''
    except KeyboardInterrupt:
        raise SystemExit('aborted')
    if failure:
        print(f'storyboard failed: {failure}\n--- last screen ---\n{screen}', file=sys.stderr)
        raise SystemExit(1)
    total = sum(seconds for _, seconds in timings)
    for scene, seconds in timings:
        print(f'{scene:16} {seconds:6.1f} s', file=sys.stderr)
    print(f"{'total':16} {total:6.1f} s", file=sys.stderr)


if __name__ == '__main__':
    main()
