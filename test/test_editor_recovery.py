"""Real Fresh backend lifetime and recovery; isolated files and owned processes."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


def eventually(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError("Timed out waiting for editor state")


class Client:
    def __init__(self, binary, root, env, session):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        self.process = subprocess.Popen(
            [str(binary), "--no-plugins", "--no-upgrade-check", "-a", session],
            cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True)
        os.close(slave)
        self.output = bytearray()

    def pump(self, seconds=0.1):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.025)[0]:
                try:
                    data = os.read(self.master, 65536)
                    self.output.extend(data)
                    if b"\x1b[6n" in data:
                        os.write(self.master, b"\x1b[1;1R")
                    if b"\x1b[?u" in data:
                        os.write(self.master, b"\x1b[?0u")
                except OSError:
                    break
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", self.output)

    def wait_text(self, *texts):
        eventually(lambda: all(text in self.pump() for text in texts))

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGHUP)
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        os.close(self.master)

    def detach(self, key=b"\x1b[21~"):
        os.write(self.master, key)
        eventually(lambda: (self.pump() is not None) and self.process.poll() is not None)
        assert self.process.returncode == 0, "Detach did not return successfully"
        self.stop()


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="fc-er-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        for name in ("home", "config", "data", "cache", "runtime"):
            (root / name).mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(root / "home"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                   XDG_CACHE_HOME=str(root / "cache"), XDG_RUNTIME_DIR=str(root / "runtime"),
                   TERM="xterm-256color", RUST_LOG="warn", FRESH_SESSION_IDLE_TIMEOUT_SECS="3",
                   FC_EDITOR_SWITCH_KEY="f10")
        files = [root / "alpha.txt", root / "beta.txt"]
        for path in files:
            path.write_text("ORIGINAL\n")
        session = "recovery-test"
        pidfile = root / "runtime" / "fresh" / (session + ".pid")
        clients, owned = [], set()
        # Keep the launching shell group alive so SIGHUP really reaches it.
        opener = subprocess.Popen(
            [sys.executable, "-c",
             "import subprocess,sys,time; r=subprocess.run(sys.argv[1:]); "
             "print(r.returncode,flush=True); time.sleep(60)",
             str(binary), "--cmd", "session", "open-file", session, *map(str, files)],
            cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True)
        try:
            concurrent = subprocess.run([str(binary), "--cmd", "session", "open-file", session, *map(str, files)],
                                        cwd=root, env=env, capture_output=True, timeout=15)
            assert select.select([opener.stdout], [], [], 15)[0], "Opener did not finish"
            initial_code = int(opener.stdout.readline().strip())
            assert sorted([initial_code, concurrent.returncode]) == [0, 2], "Concurrent launch started multiple backends"
            pid = int(pidfile.read_text())
            owned.add(pid)
            assert os.getpgid(pid) == pid, "Backend inherited the shell process group"
            first = Client(binary, root, env, session)
            clients.append(first)
            first.wait_text(b"alpha.txt", b"beta.txt", b"Ln 1, Col 1")
            os.write(first.master, b"UNSAVED_SENTINEL")
            first.wait_text(b"UNSAVED_SENTINEL")
            first.stop()
            clients.remove(first)
            os.killpg(opener.pid, signal.SIGHUP)
            opener.wait(timeout=3)
            os.kill(pid, 0)
            second = Client(binary, root, env, session)
            clients.append(second)
            second.wait_text(b"alpha.txt", b"beta.txt", b"UNSAVED_SENTINEL")
            assert int(pidfile.read_text()) == pid
            assert all(path.read_text() == "ORIGINAL\n" for path in files)
            print("PASS editor survives client disconnect and shell process-group hangup")

            def checkpoint():
                paths = list(root.rglob(session + ".json"))
                return json.loads(paths[0].read_text()) if paths else {}

            def has_text(text):
                return any(text in (b["text"] or "") for b in checkpoint().get("buffers", []))

            eventually(lambda: has_text("UNSAVED_SENTINEL"))
            def view_state():
                saved = checkpoint()
                names = {json.dumps(b["id"]): b["path"] or b["name"] for b in saved["buffers"]}
                return [(tuple(names.get(json.dumps(i)) for i in view["tabs"]),
                         names.get(json.dumps(view["active"])), view["cursor"])
                        for view in saved["views"]]
            saved_view = view_state()
            assert saved_view[0][0] == tuple(map(str, files)), ("Opened file order not retained", saved_view, files)
            assert saved_view[0][1] == str(files[1]) and saved_view[0][2] == len("UNSAVED_SENTINEL")
            second.detach()
            clients.remove(second)
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.2)
            third = Client(binary, root, env, session)
            clients.append(third)
            third.wait_text(b"alpha.txt", b"beta.txt", b"UNSAVED_SENTINEL")
            third.wait_text(("Ln 1, Col " + str(len("UNSAVED_SENTINEL") + 1)).encode())
            assert view_state() == saved_view, "Recovered tabs, active file or cursor changed"
            pid = int(pidfile.read_text())
            owned.add(pid)
            # A clean tab closed by Fresh must stay closed after backend loss.
            subprocess.run([str(binary), "--cmd", "session", "open-file", session, str(files[0])],
                           cwd=root, env=env, capture_output=True, check=True, timeout=12)
            third.pump(0.3)
            os.write(third.master, b"\x1bw")  # Alt+W: close clean alpha tab
            eventually(lambda: (third.pump() is not None) and checkpoint() and
                       not any(b["path"] == str(files[0]) for b in checkpoint()["buffers"]))
            os.write(third.master, b"\x0e")  # Ctrl+N: untitled buffer
            third.pump(0.3)
            os.write(third.master, b"UNTITLED_SENTINEL")
            third.wait_text(b"UNTITLED_SENTINEL")
            eventually(lambda: has_text("UNTITLED_SENTINEL"))
            third.detach()
            clients.remove(third)
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.2)
            fourth = Client(binary, root, env, session)
            clients.append(fourth)
            fourth.wait_text(b"beta.txt", b"UNTITLED_SENTINEL")
            owned.add(int(pidfile.read_text()))
            assert b"alpha.txt" not in fourth.pump(), "Editor-closed tab was resurrected"
            assert has_text("UNSAVED_SENTINEL"), "Inactive dirty buffer lost on second restart"
            assert all(path.read_text() == "ORIGINAL\n" for path in files)
            fourth.detach()
            clients.remove(fourth)
            env["FC_EDITOR_SWITCH_KEY"] = "f8"
            fifth = Client(binary, root, env, session)
            clients.append(fifth)
            fifth.wait_text(b"beta.txt", b"UNTITLED_SENTINEL")
            fifth.detach(b"\x1b[19~")
            clients.remove(fifth)
            time.sleep(3.5)
            os.kill(int(pidfile.read_text()), 0)
            print("PASS dirty and untitled buffers survive backend loss; closed tabs stay closed")
            print("PASS idle timeout retains detached dirty buffers")
            print("PASS F10 and per-attachment key override detach without closing buffers")
            clean_session = "clean-idle-test"
            opened = subprocess.run([str(binary), "--cmd", "session", "open-file", clean_session, *map(str, files)],
                                    cwd=root, env=env, capture_output=True, timeout=15)
            assert opened.returncode == 2, opened.stderr
            clean_pidfile = pidfile.with_name(clean_session + ".pid")
            owned.add(int(clean_pidfile.read_text()))
            clean = Client(binary, root, env, clean_session)
            clients.append(clean)
            clean.wait_text(b"alpha.txt", b"beta.txt")
            clean.detach(b"\x1b[19~")
            clients.remove(clean)
            eventually(lambda: not clean_pidfile.exists(), 8)
            restored = Client(binary, root, env, clean_session)
            clients.append(restored)
            restored.wait_text(b"alpha.txt", b"beta.txt", b"ORIGINAL")
            owned.add(int(clean_pidfile.read_text()))
            restored.detach(b"\x1b[19~")
            clients.remove(restored)
            print("PASS clean idle exit checkpoints tabs and restores them on the next attachment")
        finally:
            for client in clients:
                client.stop()
            if opener.poll() is None:
                os.killpg(opener.pid, signal.SIGKILL)
                opener.wait(timeout=3)
            if pidfile.exists():
                owned.add(int(pidfile.read_text()))
            for pid in owned:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    main()
