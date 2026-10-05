"""Checkpoint-confirmed restart, failure refusal and legacy opt-in."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading

from test_editor_recovery import Client, eventually


def environment(root):
    for name in ("home", "config", "data", "cache", "runtime"):
        (root / name).mkdir(mode=0o700)
    return dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
                XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
                XDG_RUNTIME_DIR=str(root / "runtime"), TERM="xterm-256color",
                FC_EDITOR_SWITCH_KEY="f10", FRESH_SESSION_IDLE_TIMEOUT_SECS="120")


def prepare(binary, root, env, name="restart-test", legacy=False):
    return subprocess.run([str(binary), "--cmd", "session", "prepare-restart", name]
                          + (["--allow-legacy-checkpoint"] if legacy else []),
                          cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=25)


def real_restart(binary):
    with tempfile.TemporaryDirectory(prefix="fc-restart-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        env = environment(root)
        source = root / "source.txt"; source.write_text("ORIGINAL\n")
        pidfile = root / "runtime/fresh/restart-test.pid"
        client = None
        try:
            assert prepare(binary, root, env).returncode == 0
            assert not pidfile.exists(), "Preparing an absent editor spawned a backend"
            opened = subprocess.run([str(binary), "--cmd", "session", "open-file", "restart-test", str(source)],
                                    cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert opened.returncode == 0, opened.stderr
            pid = int(pidfile.read_text())
            client = Client(binary, root, env, "restart-test")
            client.wait_text(b"ORIGINAL")
            os.write(client.master, b"RESTART_DIRTY_")
            client.wait_text(b"RESTART_DIRTY_")
            blocked = prepare(binary, root, env)
            assert blocked.returncode == 1 and b"Detach other editor clients" in blocked.stderr, blocked
            assert int(pidfile.read_text()) == pid
            os.write(client.master, b"\x0e")
            client.pump(0.2)
            os.write(client.master, b"RESTART_UNTITLED_")
            client.wait_text(b"RESTART_UNTITLED_")
            client.detach(); client = None

            # A real filesystem failure must not become a best-effort shutdown.
            data = next(root.rglob("fc-daemons/restart-test"))
            workspaces = data / "workspaces"
            saved = data / "workspaces.saved"
            workspaces.rename(saved)
            workspaces.write_text("block workspace checkpoint")
            blocked = prepare(binary, root, env)
            assert blocked.returncode == 1 and b"remains running" in blocked.stderr, blocked
            assert int(pidfile.read_text()) == pid
            os.kill(pid, 0)
            workspaces.unlink(); saved.rename(workspaces)

            client = Client(binary, root, env, "restart-test")
            client.wait_text(b"RESTART_UNTITLED_")
            client.detach(); client = None
            result = prepare(binary, root, env)
            assert result.returncode == 0, result.stderr
            assert not pidfile.exists(), "Restart reported success before backend shutdown"
            assert source.read_text() == "ORIGINAL\n", "Restart saved over the original file"
            client = Client(binary, root, env, "restart-test")
            client.wait_text(b"source.txt", b"RESTART_UNTITLED_")
            assert int(pidfile.read_text()) != pid
            opened = subprocess.run([str(binary), "--cmd", "session", "open-file", "restart-test", str(source)],
                                    cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert opened.returncode == 0, opened.stderr
            client.wait_text(b"RESTART_DIRTY_")
            assert source.read_text() == "ORIGINAL\n"
            client.detach(); client = None
            print("PASS restart restores dirty and untitled tabs; failed checkpoints and active clients retain the backend")
        finally:
            if client: client.stop()
            if pidfile.exists():
                try: os.kill(int(pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass


def legacy_consent(binary):
    """Protocol-2 backend: no Quit before explicit legacy consent."""
    with tempfile.TemporaryDirectory(prefix="fc-restart-v2-", dir="/tmp") as directory:
        root = Path(directory).resolve(); env = environment(root)
        sockets = root / "runtime/fresh"; sockets.mkdir()
        paths = [sockets / ("legacy." + suffix) for suffix in ("data.sock", "ctrl.sock")]
        listeners = []
        for path in paths:
            listener = socket.socket(socket.AF_UNIX); listener.bind(str(path)); listener.listen(); listener.settimeout(10)
            listeners.append(listener)
        # Isolated helper PID makes liveness deterministic without touching a
        # user process. The mock owns its shutdown too.
        sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(40)"])
        pidfile = sockets / "legacy.pid"; pidfile.write_text(str(sleeper.pid))
        received, errors = [], []

        def server():
            try:
                # First (unconfirmed) probe, then confirmed v4 -> v2 negotiation.
                for _ in range(3):
                    with listeners[0].accept()[0] as data, listeners[1].accept()[0] as control:
                        control.settimeout(8)
                        reader = control.makefile("rb")
                        hello = json.loads(reader.readline())
                        if hello["protocol_version"] == 4:
                            reply = dict(type="version_mismatch", server_version="0.2.3", client_version="0.5.2",
                                         action="upgrade_server", message="Protocol version mismatch: server=2, client=4")
                        else:
                            assert hello["protocol_version"] == 2
                            reply = dict(type="hello", protocol_version=2, server_version="0.2.3", session_id="legacy")
                        control.sendall((json.dumps(reply) + "\n").encode())
                        line = reader.readline()
                        if line:
                            received.append(json.loads(line)["type"])
                            assert received == ["quit"]
                            sleeper.terminate(); sleeper.wait(timeout=3)
                            pidfile.unlink()
                            for path in paths: path.unlink()
                        reader.close()
            except Exception as error: errors.append(error)

        worker = threading.Thread(target=server, daemon=True); worker.start()
        try:
            result = prepare(binary, root, env, "legacy")
            assert result.returncode == 20, result.stderr
            assert sleeper.poll() is None and not received, "Legacy backend stopped without consent"
            result = prepare(binary, root, env, "legacy", legacy=True)
            assert result.returncode == 0, result.stderr
            worker.join(5)
            assert not worker.is_alive() and not errors and received == ["quit"], errors
            print("PASS legacy restart requires opt-in, negotiates old protocol and waits for shutdown")
        finally:
            if sleeper.poll() is None: sleeper.terminate(); sleeper.wait(timeout=3)
            for listener in listeners: listener.close()


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    real_restart(binary)
    legacy_consent(binary)
