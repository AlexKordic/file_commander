"""R33: unpacked script mode runs without a source-tree working directory."""
from pathlib import Path
import sys
import tarfile
import tempfile
from lua_runner import run_script

repo = Path(__file__).resolve().parent.parent
archive = Path(sys.argv[1]) if len(sys.argv) > 1 else next((repo / 'build/dist').glob('*.tar.gz'))
with tempfile.TemporaryDirectory(prefix='fc-package-test-') as temp:
    root = Path(temp)
    with tarfile.open(archive) as package:
        package.extractall(root / 'package', filter='data')
    binary = next((root / 'package').glob('*/bin/fc'))
    unrelated = root / 'unrelated'
    unrelated.mkdir()
    script = unrelated / 'check.lua'
    script.write_text("check(type(fc.key)=='function', 'embedded framework'); fc.key({}); assert(fc.wait_for_jobs(1)); test_pass('packaged_script')")
    rc, seconds, killed, output = run_script(binary, script, unrelated, root / 'config', 5)
    assert not killed and rc == 0 and b'[PASS] packaged_script' in output, f'packaged script failed: exit={rc}, timeout={killed}'
    assert not (unrelated / 'fc_framework.lua').exists()
    print(f'PASS packaged_script: exit={rc}, elapsed={seconds:.2f}s')
