#!/usr/bin/env python3
"""OpenSSH test double: run FC's exact helper, optionally lose a commit reply."""
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
if not marker:
    os.execv(sys.executable, [sys.executable, *command[1:]])
# Test only: proxy the exact helper and drop its acknowledgement after it has
# renamed the staging entry. The coordinator must reconcile, never replay.
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
        if 'result' in value and request['method'] == 'rename' and not Path(marker).exists():
            Path(marker).touch(); child.terminate(); child.wait(timeout=3); sys.exit(91)
        sys.stdout.buffer.write(reply); sys.stdout.buffer.flush()
        if 'result' in value or 'error' in value:
            break
child.terminate(); child.wait(timeout=3)
