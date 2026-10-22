#!/usr/bin/env python3
"""Run FC's exact SSH helper with optional reply loss or metadata overrides."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
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
if not (marker or platform or acl):
    os.execv(sys.executable, [sys.executable, *command[1:]])
# Test only: proxy the exact helper to exercise cross-platform metadata policy
# without needing another OS, or lose an acknowledgement after commit.
length = int(re.search(r'read\((\d+)\)', command[-1])[1])
source = sys.stdin.buffer.read(length)
child = subprocess.Popen([sys.executable, '-u', '-c', source.decode()], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
sys.stdout.buffer.write(wire_exact(child.stdout, len(WIRE_HELLO))); sys.stdout.buffer.flush()

def requests():
    try:
        while (request := wire_read(sys.stdin.buffer)) is not None:
            wire_write(child.stdin, *request)
    finally:
        child.stdin.close()

# Keep the proxy duplex: it must not insert a per-request response wait into
# the real streaming protocol, including under cross-platform fault injection.
threading.Thread(target=requests, daemon=True).start()
while (frame := wire_read(child.stdout)) is not None:
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
