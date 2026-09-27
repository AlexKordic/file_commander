"""Run fc scripts in an isolated PTY and retain exit status and terminal output."""
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


def run_script(binary, script, cwd, config, timeout=45, extra_env=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", XDG_CONFIG_HOME=str(config))
    env.update(extra_env or {})
    process = subprocess.Popen([str(Path(binary).resolve()), "run", str(script)],
                               stdin=slave, stdout=slave, stderr=slave, cwd=cwd,
                               env=env, start_new_session=True)
    os.close(slave)
    output = bytearray()
    start = time.monotonic()
    timed_out = False
    try:
        while process.poll() is None:
            if time.monotonic() - start >= timeout:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                break
            if select.select([master], [], [], 0.05)[0]:
                try:
                    data = os.read(master, 65536)
                    if data:
                        output.extend(data)
                except OSError:
                    pass
        process.wait(timeout=2)
        while select.select([master], [], [], 0)[0]:
            try:
                data = os.read(master, 65536)
                if not data:
                    break
                output.extend(data)
            except OSError:
                break
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        os.close(master)
    return process.returncode, time.monotonic() - start, timed_out, bytes(output)
