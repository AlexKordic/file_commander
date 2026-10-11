#!/usr/bin/env python3
"""Records scene messages from a real Fresh session into a FreshKit test fixture.

    macos/tools/record_scene.py [FRESH] [OUT]

FRESH defaults to build-macos/third_party/fresh/bin/fresh; OUT to
macos/Tests/FreshKitTests/Fixtures/scene.json. The script starts a throwaway
File Commander session in a temporary HOME, opens a small file, connects to the
session's scene socket at 80x24 the way the app does, types a few keys and
writes the hello and the frames that answered them. Rerun it after bumping the
Fresh pin; the FreshKit tests then check the app still reads what Fresh sends.
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRESH = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build-macos/third_party/fresh/bin/fresh'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / 'macos/Tests/FreshKitTests/Fixtures/scene.json'
CONFIG = {
    'check_for_updates': False,
    'theme': 'dark',
    'editor': {'auto_close': False, 'auto_indent': False},
    'plugins': {
        'orchestrator': {'enabled': True, 'settings': {'autoOpenDock': 'never'}},
        'welcome_screen': {'enabled': True, 'settings': {'showOnStartup': False}},
    },
}


class Scene:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET /ws?grid=1&menus=native HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                           f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            buf += self.sock.recv(65536)
        head, self.buf = buf.split(b'\r\n\r\n', 1)
        assert b' 101 ' in head.split(b'\r\n')[0], head

    def send(self, message):
        self.sock.settimeout(None)
        data = json.dumps(message).encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('>H', n))
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def message(self, timeout):
        self.sock.settimeout(timeout)
        while True:
            if len(self.buf) >= 2:
                opcode, n, offset = self.buf[0] & 0x0F, self.buf[1] & 0x7F, 2
                ready = True
                if n == 126:
                    ready = len(self.buf) >= 4
                    if ready:
                        n, offset = struct.unpack('>H', self.buf[2:4])[0], 4
                elif n == 127:
                    ready = len(self.buf) >= 10
                    if ready:
                        n, offset = struct.unpack('>Q', self.buf[2:10])[0], 10
                if ready and len(self.buf) >= offset + n:
                    payload, self.buf = self.buf[offset:offset + n], self.buf[offset + n:]
                    if opcode == 1:
                        return json.loads(payload)
                    continue
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
        sample.write_text('# Notes\n\nFirst line.\n')
        env = dict(os.environ, HOME=home, FC_EDITOR_SWITCH_KEY='f10')
        name = f'fc-record-{os.getpid()}'
        run = lambda *args: subprocess.run([str(FRESH), '--cmd', 'session', *args], env=env, cwd=work,
                                           stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
        try:
            ensured = json.loads(run('ensure', name).stdout.strip().splitlines()[-1])
            run('open-location', name, '-', str(work), '-', str(sample))
            first = Scene(ensured['scene'])
            first.message(10)
            first.send({'type': 'resize', 'cols': 80, 'rows': 24})
            first.drain(1.5)
            first.sock.close()
            time.sleep(0.3)
            scene = Scene(ensured['scene'])
            messages = [scene.message(10)]
            messages += scene.drain(0.8)
            for key in ['End', 'ArrowDown', 'ArrowDown', 'End']:
                scene.send({'type': 'key', 'key': key.replace('ArrowDown', 'ArrowDown')})
            for character in ' (recorded)':
                scene.send({'type': 'key', 'key': character})
            messages += scene.drain(1.0)
            scene.send({'type': 'action', 'action': 'command_palette'})
            messages += scene.drain(0.8)
            scene.send({'type': 'key', 'key': 'Escape'})
            messages += scene.drain(0.6)
            scene.sock.close()
        finally:
            subprocess.run([str(FRESH), '--cmd', 'session', 'kill', name], env=env, stdin=subprocess.DEVNULL, capture_output=True)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps([m for m in messages if m], separators=(',', ':')) + '\n')
    hello = messages[0]['scene']
    print(f'{OUT}: hello {hello["w"]}x{hello["h"]}, {len(messages) - 1} frames, {OUT.stat().st_size} bytes')


if __name__ == '__main__':
    sys.exit(main())
