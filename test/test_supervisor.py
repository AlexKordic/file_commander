"""Exercise real processes, descriptor ownership and bounded capture."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from lua_runner import run_script
from test_results import require

with tempfile.TemporaryDirectory(prefix='fc-supervisor-') as directory:
    root = Path(directory)
    def executable(name, body):
        path = root / name
        path.write_text('#!' + sys.executable + '\n' + body)
        path.chmod(0o700)
        return path
    quick = executable('quick', "print('[PASS] quick')\n")
    fail = executable('fail', 'raise SystemExit(13)\n')
    crash = executable('signal', 'import os, signal\nos.kill(os.getpid(), signal.SIGTERM)\n')
    noisy = executable('noisy', "import os\nfor _ in range(128): os.write(1, b'x'*65536)\nprint('FINAL')\n")
    hang = executable('hang', 'import time\ntime.sleep(30)\n')
    def run(binary):
        return run_script(binary, root/'unused', root, root/(binary.name+'-config'), timeout=2, output_limit=4096)
    descriptors = Path('/dev/fd')
    before = len(list(descriptors.iterdir()))
    for _ in range(8):
        try:
            run(root/'missing')
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError('spawn failure accepted')
    require(len(list(descriptors.iterdir())) == before, 'spawn failures leak PTY descriptors')
    require(run(fail)[0] == 13, 'failed exit lost')
    require(run(crash)[0] == -signal.SIGTERM, 'signal lost')
    result = run(noisy)
    require(result[0] == 0 and len(result[3]) <= 4096 and b'FINAL' in result[3], 'noisy output is not bounded tail')
    require(run(hang)[2], 'deadline not reported')
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run, [quick]*8))
    require(all(r[0] == 0 and b'[PASS] quick' in r[3] for r in results), 'parallel runs interfere')
    child_pids = root/'children'
    tree = executable('tree', '''import os, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"], start_new_session=True); print(p.pid,flush=True); time.sleep(30)'], start_new_session=True, stdout=open(sys.argv[2], 'w'))
with open(sys.argv[2] + '.parent', 'w') as f: f.write(str(child.pid))
time.sleep(30)
''')
    result = run_script(tree, child_pids, root, root/'tree-config', timeout=0.7)
    require(result[2], 'tree did not time out')
    for path in (child_pids, Path(str(child_pids)+'.parent')):
        pid = int(path.read_text())
        for _ in range(50):
            state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
            if not state or state.startswith('Z'):
                break
            time.sleep(0.02)
        require(not state or state.startswith('Z'), f'owned descendant {pid} survived')
    require(len(list(descriptors.iterdir())) == before, 'supervision leaks descriptors')
print('PASS supervisor: spawn/exit/signal/deadline/output/descendants/concurrency')
