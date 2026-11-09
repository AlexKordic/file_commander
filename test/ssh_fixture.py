#!/usr/bin/env python3
"""Run FC's exact SSH helper with optional reply loss or metadata overrides."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from remote_protocol import *
if sys.argv[-2] == "fixture-offline":
    print("SSH fixture: host is offline", file=sys.stderr)
    sys.exit(255)
command = shlex.split(sys.argv[-1])
assert command[:3] == ['python3', '-u', '-c']
marker = os.environ.get('FC_SSH_FIXTURE_DROP_RENAME')
platform = os.environ.get('FC_SSH_FIXTURE_PLATFORM')
acl = os.environ.get('FC_SSH_FIXTURE_ACL')
gate = os.environ.get('FC_SSH_FIXTURE_STREAM_GATE')
trace = os.environ.get('FC_SSH_FIXTURE_STREAM_TRACE')
fault = os.environ.get('FC_SSH_FIXTURE_STREAM_FAULT')
if not (marker or platform or acl or gate or trace or fault):
    os.execv(sys.executable, [sys.executable, *command[1:]])
# Test only: proxy the exact helper to exercise cross-platform metadata policy
# without needing another OS, or lose an acknowledgement after commit.
length = int(re.search(r'read\((\d+)\)', command[-1])[1])
source = sys.stdin.buffer.read(length)
wrapper = '''
import errno, os, threading
from pathlib import Path
namespace = {'__name__': 'fc_fixture_agent'}
exec(SOURCE, namespace)
Writer = namespace['StreamWriter']
first, ended = [None], [0]
entered, release = threading.Event(), threading.Event()
original_init, original_end, original_write = Writer.__init__, Writer.end, Writer.write
original_fsync = os.fsync
gate, fault = os.environ.get('FC_SSH_FIXTURE_STREAM_GATE'), os.environ.get('FC_SSH_FIXTURE_STREAM_FAULT')

def initialize(self, *args, **kwargs):
    original_init(self, *args, **kwargs)
    if first[0] is None:
        first[0] = self.fd

def fsync(fd):
    if gate and fd == first[0]:
        Path(gate + '.entered').touch()
        entered.set()
        if not release.wait(10):
            raise OSError(errno.ETIMEDOUT, 'Next file waited for the previous verification/fsync')
    return original_fsync(fd)

def end(self, digest):
    original_end(self, digest)
    ended[0] += 1
    if gate and ended[0] == 2:
        if not entered.wait(5):
            raise OSError(errno.ETIMEDOUT, 'First verifier did not reach fsync')
        Path(gate + '.second-ended').touch()
        release.set()

def write(self, data):
    if self.fd == first[0] and not self.written:
        if fault == 'disk-full':
            raise OSError(errno.ENOSPC, 'Injected destination disk full')
        if fault == 'corrupt' and data:
            data = bytes([data[0] ^ 1]) + data[1:]
    return original_write(self, data)

Writer.__init__, Writer.end, Writer.write = initialize, end, write
os.fsync = fsync
namespace['main']()
'''.replace('SOURCE', repr(source))
child = subprocess.Popen([sys.executable, '-u', '-c', wrapper if gate or fault else source.decode()],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
sys.stdout.buffer.write(wire_exact(child.stdout, len(WIRE_HELLO))); sys.stdout.buffer.flush()

def requests():
    try:
        while (request := wire_read(sys.stdin.buffer)) is not None:
            record('in', request)
            wire_write(child.stdin, *request)
    finally:
        child.stdin.close()

# Keep the proxy duplex: it must not insert a per-request response wait into
# the real streaming protocol, including under cross-platform fault injection.
trace_fd = os.open(trace, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600) if trace else None

def record(direction, frame):
    if trace_fd is not None:
        kind, operation, identity, payload = frame
        os.write(trace_fd, f'{time.monotonic_ns()} {os.getpid()} {direction} {kind} {operation} {identity} {len(payload)}\n'.encode())

threading.Thread(target=requests, daemon=True).start()
while (frame := wire_read(child.stdout)) is not None:
    record('out', frame)
    kind, operation, identity, payload = frame
    if marker and kind == WIRE_RESULT and WIRE_METHODS[operation] == 'rename' and not Path(marker).exists():
        Path(marker).touch(); child.terminate(); child.wait(timeout=3); sys.exit(91)
    if kind == WIRE_RESULT and WIRE_METHODS[operation] == 'attributes':
        value = wire_decode(payload)
        if platform:
            value['platform'] = platform
        if acl:
            value['acl'] = True
        payload = wire_encode(value)
    wire_write(sys.stdout.buffer, kind, operation, identity, payload)
child.terminate(); child.wait(timeout=3)
