#!/usr/bin/env python3
"""Records scene messages from a real Fresh session into a FreshKit test fixture.

    macos/tools/record_scene.py [FRESH] [OUT]

FRESH defaults to build-macos/third_party/fresh/bin/fresh; OUT to
macos/Tests/FreshKitTests/Fixtures/scene.tlv. The script starts a throwaway
File Commander session in a temporary HOME, opens a small file, connects to the
session's scene socket at 80x24 the way the app does, types a few keys,
scrolls down and back up, and writes the hello and the frames that answered
them, then the hello a second connection gets, for the tests to compare with
the replayed frames. The fixture is the messages as they came off the socket:
type, length and protobuf payload each. Rerun it after bumping the Fresh pin;
the FreshKit tests then check the app still reads what Fresh sends.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRESH = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build-macos/third_party/fresh/bin/fresh'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / 'macos/Tests/FreshKitTests/Fixtures/scene.tlv'
CONFIG = {
    'check_for_updates': False,
    'theme': 'dark',
    'editor': {'auto_close': False, 'auto_indent': False},
    'plugins': {
        'orchestrator': {'enabled': True, 'settings': {'autoOpenDock': 'never'}},
        'welcome_screen': {'enabled': True, 'settings': {'showOnStartup': False}},
    },
}
# Message types (scene.proto) and the protocol version.
SERVER_HELLO, FRAME, ERROR = 1, 2, 3
CLIENT_HELLO, KEY, MOUSE, RESIZE, ACTION, APPLIED = 16, 17, 18, 19, 21, 26
VERSION = 1
SCROLL_UP, SCROLL_DOWN = 5, 6


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append(n & 0x7F | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def read_varint(data, i):
    """The varint at i and where it ends; None while it hasn't all arrived."""
    value = shift = 0
    while i < len(data):
        b = data[i]
        value |= (b & 0x7F) << shift
        i += 1
        if b < 0x80:
            return value, i
        shift += 7
    return None


def fields(**values):
    """A protobuf message of numbered fields: f1=..., f2=...; ints as varints,
    strings length-delimited, zero and empty left out as protobuf does."""
    out = b''
    for name, value in sorted(values.items(), key=lambda kv: int(kv[0][1:])):
        number = int(name[1:])
        if isinstance(value, str):
            data = value.encode()
            if data:
                out += varint(number << 3 | 2) + varint(len(data)) + data
        elif value:
            out += varint(number << 3) + varint(int(value))
    return out


def top_fields(payload):
    """A message's top-level fields: number -> varint value or bytes (the last of each)."""
    out, i = {}, 0
    while i < len(payload):
        key, i = read_varint(payload, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            out[number], i = read_varint(payload, i)
        elif wire == 2:
            n, i = read_varint(payload, i)
            out[number], i = payload[i:i + n], i + n
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        else:
            raise ValueError(f'wire type {wire}')
    return out


class Scene:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b''
        self.send(CLIENT_HELLO, f1=VERSION)

    def send(self, kind, **values):
        self.sock.settimeout(None)
        payload = fields(**values)
        self.sock.sendall(varint(kind) + varint(len(payload)) + payload)

    def message(self, timeout):
        """The next message as (type, payload, its bytes on the wire), each frame
        reported applied; None when nothing comes in time."""
        self.sock.settimeout(timeout)
        while True:
            head = read_varint(self.buf, 0)
            length = head and read_varint(self.buf, head[1])
            if length and len(self.buf) >= length[1] + length[0]:
                kind, end = head[0], length[1] + length[0]
                raw, payload, self.buf = self.buf[:end], self.buf[length[1]:end], self.buf[end:]
                assert kind != ERROR, top_fields(payload).get(1, b'').decode()
                frame = top_fields(payload) if kind == FRAME else top_fields(top_fields(payload).get(2, b''))
                self.send(APPLIED, f1=frame.get(1, 0))
                return kind, payload, raw
            try:
                chunk = self.sock.recv(1 << 20)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buf += chunk

    def drain(self, seconds):
        out, end = [], time.time() + seconds
        while time.time() < end:
            message = self.message(0.1)
            if message:
                out.append(message)
        return out


def main():
    with tempfile.TemporaryDirectory(prefix='fc-scene-') as home:
        (Path(home) / '.config/fresh').mkdir(parents=True)
        (Path(home) / '.config/fresh/config.json').write_text(json.dumps(CONFIG))
        work = Path(home) / 'work'
        work.mkdir()
        sample = work / 'notes.md'
        sample.write_text('# Notes\n\nFirst line.\n' + ''.join(f'Line {n} of the notes.\n' for n in range(4, 80)))
        env = dict(os.environ, HOME=home, FC_EDITOR_SWITCH_KEY='f10')
        name = f'fc-record-{os.getpid()}'
        run = lambda *args: subprocess.run([str(FRESH), '--cmd', 'session', *args], env=env, cwd=work,
                                           stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
        try:
            ensured = json.loads(run('ensure', name).stdout.strip().splitlines()[-1])
            run('open-location', name, '-', str(work), '-', str(sample))
            first = Scene(ensured['scene'])
            first.message(10)
            first.send(RESIZE, f1=80, f2=24)
            first.drain(1.5)
            first.sock.close()
            time.sleep(0.3)
            scene = Scene(ensured['scene'])
            messages = [scene.message(10)]
            messages += scene.drain(0.8)
            for key in ['End', 'ArrowDown', 'ArrowDown', 'End', *' (recorded)']:
                scene.send(KEY, f1=key)
            messages += scene.drain(1.0)
            scene.send(ACTION, f1='command_palette')
            messages += scene.drain(0.8)
            scene.send(KEY, f1='Escape')
            messages += scene.drain(0.6)
            for kind in [SCROLL_DOWN] * 4 + [SCROLL_UP] * 4:
                scene.send(MOUSE, f1=kind, f3=40, f4=10, f5=1, f6=1)
                messages += scene.drain(0.2)
            messages += scene.drain(0.6)
            reference = Scene(ensured['scene'])
            messages.append(reference.message(10))
            reference.sock.close()
            scene.sock.close()
        finally:
            subprocess.run([str(FRESH), '--cmd', 'session', 'kill', name], env=env, stdin=subprocess.DEVNULL, capture_output=True)
    messages = [m for m in messages if m]
    assert messages[0][0] == SERVER_HELLO and messages[-1][0] == SERVER_HELLO, [m[0] for m in messages]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(b''.join(raw for _, _, raw in messages))
    hello = top_fields(top_fields(messages[0][1])[2])
    copies = sum(1 for kind, payload, _ in messages if kind == FRAME and 9 in top_fields(payload))
    print(f'{OUT}: hello {hello.get(2)}x{hello.get(3)}, {len(messages) - 2} frames ({copies} with row copies), '
          f'{OUT.stat().st_size} bytes')


if __name__ == '__main__':
    sys.exit(main())
