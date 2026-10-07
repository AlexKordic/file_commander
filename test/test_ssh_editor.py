"""One real Fresh backend routes local and SSH buffers and saves through the agent.

Default: exact Python SSH agent over the local transport fixture. --host box:
real OpenSSH, with all remote mutations inside an owned /tmp directory.
"""
import argparse
import base64
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from test_editor_recovery import Client, eventually
from test_editor_restart import environment

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
parser.add_argument('--host')
args = parser.parse_args()
binary = args.binary.resolve()
ssh = '/usr/bin/ssh'
remote = None
client = None
pid = None

def native(script, *values):
    # Constant bootstrap; only base64 OS bytes appear in its quoted arguments.
    command = 'python3 -c ' + "'" + script.replace("'", "'\\''") + "'"
    for value in values:
        command += ' ' + base64.b64encode(os.fsencode(value)).decode()
    return subprocess.check_output([ssh, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', args.host, command], text=True, timeout=20).strip()

with tempfile.TemporaryDirectory(prefix='fc-ssh-editor-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    env = environment(root)
    env['FRESH_SESSION_IDLE_TIMEOUT_SECS'] = '120'
    local = root / 'local'; local.mkdir()
    source = local / 'alpha.txt'; source.write_text('LOCAL_MARKER\n')
    if args.host:
        remote = native('import tempfile; print(tempfile.mkdtemp(prefix="fc-ssh-editor-",dir="/tmp"))')
        native('import sys,base64,pathlib; p=pathlib.Path(base64.b64decode(sys.argv[1]).decode())/"alpha.txt"; p.write_text("REMOTE_MARKER\\n")', remote)
    else:
        remote = str(root / 'remote'); Path(remote).mkdir(); Path(remote, 'alpha.txt').write_text('REMOTE_MARKER\n')
        bins = root / 'bin'; bins.mkdir()
        (bins / 'ssh').symlink_to(Path(__file__).resolve().parent / 'ssh_fixture.py')
        env['PATH'] = str(bins) + os.pathsep + env['PATH']
    target = args.host or 'fixture'
    session = 'fc-ssh-editor-test'
    pidfile = root / 'runtime/fresh' / (session + '.pid')

    def open_location(target, project, file):
        result = subprocess.run([str(binary), '--no-upgrade-check', '--cmd', 'session', 'open-location', session, target, str(project), '-', str(file)],
                                cwd=local, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=25)
        if result.returncode:
            print(result.stderr.decode(errors='replace'), file=sys.stderr)
        result.check_returncode()

    try:
        open_location('-', local, source)
        eventually(pidfile.exists)
        pid = int(pidfile.read_text())
        client = Client(binary, local, env, session); client.wait_text(b'LOCAL_MARKER')
        os.write(client.master, b'DIRTY_LOCAL_'); client.wait_text(b'DIRTY_LOCAL_'); client.detach(); client = None
        open_location(target, remote, remote + '/alpha.txt')
        assert int(pidfile.read_text()) == pid, 'Remote open launched a second daemon'
        client = Client(binary, local, env, session); client.wait_text(b'REMOTE_MARKER')
        os.write(client.master, b'REMOTE_SAVED_'); client.wait_text(b'REMOTE_SAVED_'); os.write(client.master, b'\x13')
        def saved():
            if args.host:
                return 'REMOTE_SAVED_' in native('import sys,base64,pathlib; print((pathlib.Path(base64.b64decode(sys.argv[1]).decode())/"alpha.txt").read_text())', remote)
            return 'REMOTE_SAVED_' in Path(remote, 'alpha.txt').read_text()
        eventually(saved)
        client.detach(); client = None
        open_location('-', local, source)
        client = Client(binary, local, env, session); client.wait_text(b'DIRTY_LOCAL_', b'LOCAL_MARKER')
        assert source.read_text() == 'LOCAL_MARKER\n', 'Switching silently saved the local dirty buffer'
        assert int(pidfile.read_text()) == pid, 'Switching changed the daemon identity'
        client.detach(); client = None
        print('PASS one Fresh backend: SSH edit/save, switching, dirty local tab retained on ' + target)
    except Exception:
        if client:
            screen = client.pump().decode(errors='replace')[-8000:]
            print('Editor screen at failure:\n' + screen, file=sys.stderr)
        print('Remote test fixture: ' + remote, file=sys.stderr)
        raise
    finally:
        if client: client.stop()
        if pid:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        if args.host and remote:
            assert remote.startswith('/tmp/fc-ssh-editor-')
            native('import sys,base64,shutil; shutil.rmtree(base64.b64decode(sys.argv[1]).decode())', remote)
