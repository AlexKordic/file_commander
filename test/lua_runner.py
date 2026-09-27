"""Bounded POSIX PTY supervisor shared by integration and harness tests."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time

OUTPUT_LIMIT = 2 * 1024 * 1024


def process_tree(root, known):
    # Include start identity to avoid signalling a PID reused during teardown.
    rows = subprocess.run(['ps', '-eo', 'pid=,ppid=,lstart='], capture_output=True,
                          text=True, timeout=2, check=True).stdout.splitlines()
    table = {}
    for row in rows:
        fields = row.split(None, 2)
        if len(fields) == 3:
            table[int(fields[0])] = (int(fields[1]), fields[2])
    parents = {root} | {pid for pid, identity in known.items()
                               if pid in table and table[pid][1] == identity}
    while True:
        children = {pid for pid, (parent, _) in table.items() if parent in parents}
        if children <= parents:
            break
        parents |= children
    for pid in parents - {root}:
        if pid in table:
            known[pid] = table[pid][1]
    return table


def run_script(binary, script, cwd, config, timeout=45, extra_env=None,
               output_limit=OUTPUT_LIMIT, on_tick=None):
    """Return (status, seconds, timed_out, bounded output tail).

    on_tick(master_fd, elapsed) may send real terminal input/resize. Track owned
    descendants while their ancestry is observable, including separate groups.
    Independent daemonization before the first observation requires OS isolation.
    """
    master = slave = process = None
    output = bytearray()
    known = {}
    start = time.monotonic()
    timed_out = False
    next_scan = 0

    def capture(data):
        output.extend(data)
        if len(output) > output_limit:
            del output[:-output_limit]

    try:
        Path(config).mkdir(parents=True, exist_ok=True)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', XDG_CONFIG_HOME=str(config),
                   FC_LUA_DEBUG_LOG=str(Path(config) / 'lua-debug.log'))
        env.update(extra_env or {})
        process = subprocess.Popen([str(Path(binary).resolve()), 'run', str(script)],
                                   stdin=slave, stdout=slave, stderr=slave, cwd=cwd,
                                   env=env, start_new_session=True)
        os.close(slave)
        slave = None
        while process.poll() is None:
            elapsed = time.monotonic() - start
            if elapsed >= next_scan:
                process_tree(process.pid, known)
                next_scan = elapsed + 0.1
            if elapsed >= timeout:
                timed_out = True
                break
            if on_tick:
                on_tick(master, elapsed)
            if select.select([master], [], [], min(0.05, max(0, timeout - elapsed)))[0]:
                try:
                    data = os.read(master, 65536)
                    if data:
                        capture(data)
                except OSError:
                    pass
    finally:
        try:
            if process is not None:
                try:
                    table = process_tree(process.pid, known)
                    for pid, identity in known.items():
                        if pid in table and table[pid][1] == identity:
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                finally:
                    # Also kill group descendants after a normal root exit.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=3)
        finally:
            if slave is not None:
                os.close(slave)
            if master is not None:
                try:
                    # Finite drain: an escaped/untracked writer cannot hang teardown.
                    for _ in range(64):
                        if not select.select([master], [], [], 0)[0]:
                            break
                        try:
                            data = os.read(master, 65536)
                            if not data:
                                break
                            capture(data)
                        except OSError:
                            break
                finally:
                    os.close(master)
    return process.returncode, time.monotonic() - start, timed_out, bytes(output)
