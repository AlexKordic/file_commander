"""Restart the real FC after signals, both in FC and in its attached editor."""
import fcntl
import json
import os
from pathlib import Path
import pty
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from test_editor_recovery import Client, eventually


class FC(Client):
    def __init__(self, binary, root, env):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        self.process = subprocess.Popen([str(binary)], cwd=root, env=env,
                                        stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True)
        os.close(slave)
        self.output = bytearray()


binary, fresh = map(lambda p: Path(p).resolve(), sys.argv[1:3])
with tempfile.TemporaryDirectory(prefix="fc-wr-", dir="/tmp") as directory:
    root = Path(directory)
    for name in ("one", "two", "right", "home", "runtime"):
        (root / name).mkdir(mode=0o700)
    for name in ("target-a", "target-b", "hidden"):
        (root / "two" / name).write_text(name)
    config = root / "config" / "file_commander"
    config.mkdir(parents=True)
    checkpoint = config / "workspace.json"
    def tab(path, **kw):
        return dict(path=str(path), focused="", filter="", selected=[], sort=0,
                    permissions=False, owner_group=False, **kw)
    left = tab(root / "two")
    left.update(focused=str(root / "two/target-b"), filter="target",
                selected=[str(root / "two/target-a")], permissions=True, owner_group=True, sort=1)
    expected = dict(version=1, left=dict(active=1, tabs=[tab(root / "one"), left]),
                    right=dict(active=0, tabs=[tab(root / "right")]), single_panel=True, focused_panel="left")
    checkpoint.write_text(json.dumps(expected))
    env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
               XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
               XDG_RUNTIME_DIR=str(root / "runtime"), TERM="xterm-256color", FC_FRESH_BIN=str(fresh))
    current = None
    try:
        for in_editor in (False, True):
            for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
                before = checkpoint.stat().st_mtime_ns
                current = FC(binary, root, env)
                eventually(lambda: (current.pump() is not None) and checkpoint.stat().st_mtime_ns != before)
                saved = json.loads(checkpoint.read_text())
                for key in ("left", "single_panel", "focused_panel"):
                    assert saved[key] == expected[key], (sig, in_editor, saved)
                if not in_editor and sig == signal.SIGHUP:
                    os.write(current.master, b"\x14")  # Ctrl+T: add a real panel tab.
                    eventually(lambda: (current.pump() is not None) and
                               len(json.loads(checkpoint.read_text())["left"]["tabs"]) == 3)
                    expected["left"] = json.loads(checkpoint.read_text())["left"]
                # The second process must not steal the profile or rewrite state.
                duplicate = subprocess.run([str(binary)], cwd=root, env=env, capture_output=True, timeout=5)
                assert duplicate.returncode == 1 and b"profile is already open" in duplicate.stderr
                if in_editor:
                    os.write(current.master, b"\x1b[21~")
                    current.wait_text(b"Ln 1, Col 1")
                os.killpg(current.process.pid, sig)
                eventually(lambda: (current.pump() is not None) and current.process.poll() is not None, 5)
                assert current.process.returncode == (-signal.SIGKILL if sig == signal.SIGKILL else 0)
                current.stop()
                current = None
                assert json.loads(checkpoint.read_text())["left"] == expected["left"]
                print("PASS workspace recovery", sig.name, "editor" if in_editor else "FC", flush=True)
    finally:
        if current:
            current.stop()
        for pidfile in (root / "runtime/fresh").glob("*.pid"):
            try:
                os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
