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
            assert sorted([initial_code, concurrent.returncode]) == [0, 0], "Concurrent launch started multiple backends"
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

            def native_data():
                return next(root.rglob("fc-daemons/" + session))

            def checkpoint():
                paths = list((native_data() / "workspaces").glob("*.json"))
                records = [json.loads(p.read_text()) for p in paths]
                return next((r for r in records if "split_states" in r), {})

            def has_text(text):
                return any(text.encode() in p.read_bytes() for p in native_data().rglob("*.chunk.*"))

            eventually(lambda: has_text("UNSAVED_SENTINEL"))
            def view_state():
                saved = checkpoint()
                result = []
                for view in saved.get("split_states", {}).values():
                    tabs = view["open_tabs"]
                    names = [str(root / t["File"]) if "File" in t else t["Unnamed"] for t in tabs]
                    active = view.get("active_tab_index") or 0
                    state = view.get("file_states", {}).get(tabs[active].get("File", ""), {}) if tabs else {}
                    result.append((tuple(names), names[active] if names else None, state.get("cursor", {}).get("position", 0)))
                return result
            eventually(lambda: view_state() and view_state()[0][2] == len("UNSAVED_SENTINEL"))
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
                       all(str(files[0]) not in view[0] for view in view_state()))
            os.write(third.master, b"\x0e")  # Ctrl+N: untitled buffer
            third.pump(0.3)
            os.write(third.master, b"UNTITLED_SENTINEL")
            third.wait_text(b"UNTITLED_SENTINEL")
            eventually(lambda: has_text("UNTITLED_SENTINEL"))
            third.detach()
            clients.remove(third)
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.2)
            files[1].write_text("EXTERNAL_NEW_VERSION\n")
            fourth = Client(binary, root, env, session)
            clients.append(fourth)
            fourth.wait_text(b"beta.txt", b"UNTITLED_SENTINEL")
            owned.add(int(pidfile.read_text()))
            assert b"alpha.txt" not in fourth.pump(), "Editor-closed tab was resurrected"
            assert has_text("UNSAVED_SENTINEL"), "Inactive dirty buffer lost on second restart"
            eventually(lambda: view_state() and len(view_state()[0][0]) == 2)
            assert len(view_state()[0][0]) == 2, "Recovery duplicated the untitled tab"
            subprocess.run([str(binary), "--cmd", "session", "open-file", session, str(files[1])],
                           cwd=root, env=env, capture_output=True, check=True, timeout=12)
            fourth.wait_text(b"UNSAVED_SENTINEL")
            assert files[0].read_text() == "ORIGINAL\n" and files[1].read_text() == "EXTERNAL_NEW_VERSION\n"
            os.write(fourth.master, b"\x1b[6;5~")  # Ctrl+PageDown: back to untitled
            fourth.output.clear()
            fourth.wait_text(b"UNTITLED_SENTINEL")
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
            print("PASS changed source files do not discard unsaved recovery or overwrite disk")
            print("PASS idle timeout retains detached dirty buffers")
            print("PASS F10 and per-attachment key override detach without closing buffers")
            clean_session = "clean-idle-test"
            opened = subprocess.run([str(binary), "--cmd", "session", "open-file", clean_session, *map(str, files)],
                                    cwd=root, env=env, capture_output=True, timeout=15)
            assert opened.returncode == 0, opened.stderr
            clean_pidfile = pidfile.with_name(clean_session + ".pid")
            owned.add(int(clean_pidfile.read_text()))
            clean = Client(binary, root, env, clean_session)
            clients.append(clean)
            clean.wait_text(b"alpha.txt", b"beta.txt")
            assert b"UNSAVED_SENTINEL" not in clean.pump() and b"UNTITLED_SENTINEL" not in clean.pump(), "Named sessions shared recovery data"
            clean.detach(b"\x1b[19~")
            clients.remove(clean)
            eventually(lambda: not clean_pidfile.exists(), 8)
            restored = Client(binary, root, env, clean_session)
            clients.append(restored)
            restored.wait_text(b"alpha.txt", b"beta.txt", b"EXTERNAL_NEW_VERSION")
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
            for record in (root / "runtime/fresh").glob("*.pid"):
                owned.add(int(record.read_text()))
            for pid in owned:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def migration(binary):
    """Fixture captured from pinned 356a988, including dirty + untitled tabs."""
    with tempfile.TemporaryDirectory(prefix="fc-migrate-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        for name in ("home", "config", "data", "cache", "runtime"):
            (root / name).mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(root / "home"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                   XDG_CACHE_HOME=str(root / "cache"), XDG_RUNTIME_DIR=str(root / "runtime"),
                   TERM="xterm-256color", FC_EDITOR_SWITCH_KEY="f10")
        data = (root / "home/Library/Application Support/fresh" if sys.platform == "darwin"
                else root / "data/fresh")
        legacy = data / "sessions/legacy-upgrade.json"
        legacy.parent.mkdir(parents=True)
        fixture = Path(__file__).with_name("fixtures") / "fresh-0.2.3-session.json"
        original = fixture.read_text().replace("@ROOT@", str(root))
        legacy.write_text(original)
        for name in ("alpha.txt", "beta.txt"):
            (root / name).write_text("ORIGINAL\n")
        client = None
        try:
            for attempt in range(2):
                client = Client(binary, root, env, "legacy-upgrade")
                client.wait_text(b"alpha.txt", b"beta.txt", b"LEGACY_UNTITLED_" if attempt == 0 else b"LEGACY_DIRTY_")
                assert legacy.with_suffix(".json.imported").read_text() == original
                assert not legacy.exists(), "Migration will replay an obsolete checkpoint"
                # Focus beta via a duplicate open: must retain unsaved text.
                subprocess.run([str(binary), "--cmd", "session", "open-file", "legacy-upgrade", str(root / "beta.txt")],
                               cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=15)
                client.wait_text(b"LEGACY_DIRTY_")
                client.detach(); client = None
                pidfile = root / "runtime/fresh/legacy-upgrade.pid"
                os.kill(int(pidfile.read_text()), signal.SIGKILL)
                time.sleep(0.2)
            assert (root / "beta.txt").read_text() == "ORIGINAL\n", "Migration saved source files"
            print("PASS old checkpoint imports dirty and untitled tabs, keeps backup, survives another restart")
            corrupt = legacy.with_name("corrupt-upgrade.json")
            corrupt.write_text('{"version":999,"broken":')
            failed = subprocess.run([str(binary), "--cmd", "session", "open-file", "corrupt-upgrade", str(root / "alpha.txt")],
                                    cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert failed.returncode != 0 and b"checkpoint retained" in failed.stderr, failed.stderr
            assert corrupt.read_text() == '{"version":999,"broken":'
            assert not corrupt.with_suffix(".json.imported").exists()
            print("PASS failed migration is reported and leaves the original recovery record intact")
        finally:
            if client: client.stop()
            for pidfile in (root / "runtime/fresh").glob("*.pid"):
                try: os.kill(int(pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass


def handshake_failures(binary):
    import socket
    import threading
    with tempfile.TemporaryDirectory(prefix="fc-handshake-", dir="/tmp") as directory:
        root = Path(directory)
        sockets = root / "runtime/fresh"; sockets.mkdir(parents=True)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"), FC_EDITOR_SWITCH_KEY="f10")
        source = root / "file.txt"; source.write_text("original")
        for version, attach in ((2, False), (4, False), (4, True), (None, False)):
            listeners = []
            for suffix in ("data.sock", "ctrl.sock"):
                listener = socket.socket(socket.AF_UNIX)
                path = sockets / ("incompatible." + suffix)
                path.unlink(missing_ok=True)
                listener.bind(str(path)); listener.listen(); listener.settimeout(15)
                listeners.append(listener)
            (sockets / "incompatible.pid").write_text(str(os.getpid()))
            done = threading.Event()
            def server():
                with listeners[0].accept()[0] as data, listeners[1].accept()[0] as control:
                    control.recv(65536)
                    if version is not None:
                        reply = ({"type": "version_mismatch", "server_version": "old", "client_version": "0.5.2",
                                  "action": "restart_server", "message": "Protocol mismatch"} if version == 2 else
                                 {"type": "hello", "protocol_version": version, "server_version": "upstream", "session_id": "incompatible"})
                        control.sendall((json.dumps(reply) + "\n").encode())
                    done.wait(15)
            worker = threading.Thread(target=server); worker.start()
            try:
                start = time.monotonic()
                if attach:
                    client = Client(binary, root, env, "incompatible")
                    try:
                        eventually(lambda: client.pump() is not None and client.process.poll() is not None)
                        code = client.process.returncode
                    finally:
                        client.stop()
                else:
                    result = subprocess.run([str(binary), "--cmd", "session", "open-file", "incompatible", str(source)],
                                            env=env, cwd=root, stdin=subprocess.DEVNULL, capture_output=True, timeout=13)
                    code = result.returncode
                assert code != 0, "Incompatible or silent server was accepted"
                assert time.monotonic() - start < 12, "Handshake exceeded its deadline"
                assert source.read_text() == "original"
                assert (sockets / "incompatible.pid").read_text() == str(os.getpid())
            finally:
                done.set(); worker.join(2)
                for listener in listeners: listener.close()
        print("PASS old/unpatched backends fail explicitly; silent handshake times out without killing server")


def startup_timeout(binary):
    """A daemon blocked reading configuration must be stopped before retry."""
    with tempfile.TemporaryDirectory(prefix="fc-startup-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        for name in ("home", "runtime", "config"):
            (root / name).mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_RUNTIME_DIR=str(root / "runtime"), FC_EDITOR_SWITCH_KEY="f10")
        config = root / "blocked-config.json"
        os.mkfifo(config)
        source = root / "file.txt"; source.write_text("STARTUP_RETRY\n")
        session = "startup-timeout"
        def blocked_pids():
            records = subprocess.check_output(["ps", "-Aww", "-o", "pid=,args="], text=True).splitlines()
            return [int(line.strip().split(None, 1)[0]) for line in records
                    if str(config) in line and "--server" in line and str(binary) in line]
        client = None
        try:
            result = subprocess.run([str(binary), "--config", str(config), "--cmd", "session", "open-file", session, str(source)],
                                    cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            assert result.returncode != 0 and b"did not start" in result.stderr, result.stderr
            eventually(lambda: not blocked_pids(), 3)
            config.unlink(); config.write_text("{}")
            subprocess.run([str(binary), "--config", str(config), "--cmd", "session", "open-file", session, str(source)],
                           cwd=root, env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=15)
            client = Client(binary, root, env, session)
            client.wait_text(b"STARTUP_RETRY")
            client.detach(); client = None
            print("PASS startup timeout stops its owned daemon; retry starts a usable editor")
        finally:
            if client: client.stop()
            owned = blocked_pids()
            owned += [int(p.read_text()) for p in (root / "runtime/fresh").glob("*.pid")]
            for pid in owned:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass


if __name__ == "__main__":
    main()
    migration(Path(sys.argv[1]).resolve())
    handshake_failures(Path(sys.argv[1]).resolve())
    startup_timeout(Path(sys.argv[1]).resolve())
