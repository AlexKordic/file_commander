#!/usr/bin/env python3
"""Run FC's exact SSH helper with optional reply loss or metadata overrides."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import json
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
sys.stdout.buffer.write(child.stdout.readline()); sys.stdout.buffer.flush()
for line in sys.stdin.buffer:
    request = json.loads(line)
    child.stdin.write(line); child.stdin.flush()
    while True:
        reply = child.stdout.readline()
        if not reply:
            sys.exit(92)
        value = json.loads(reply)
        if marker and 'result' in value and request['method'] == 'rename' and not Path(marker).exists():
            Path(marker).touch(); child.terminate(); child.wait(timeout=3); sys.exit(91)
        if 'result' in value and request['method'] == 'attributes':
            if platform:
                value['result']['platform'] = platform
            if acl:
                value['result']['acl'] = True
            reply = (json.dumps(value) + '\n').encode()
        sys.stdout.buffer.write(reply); sys.stdout.buffer.flush()
        if 'result' in value or 'error' in value:
            break
        if request['method'] == 'copy' and request['params'].get('checkpoint'):
            child.stdin.write(sys.stdin.buffer.readline()); child.stdin.flush()
child.terminate(); child.wait(timeout=3)
