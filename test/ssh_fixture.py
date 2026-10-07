#!/usr/bin/env python3
"""OpenSSH test double: run the unmodified embedded bootstrap on localhost."""
import os
import shlex
import sys
command = shlex.split(sys.argv[-1])
assert command[:3] == ['python3', '-u', '-c']
os.execv(sys.executable, [sys.executable, *command[1:]])
