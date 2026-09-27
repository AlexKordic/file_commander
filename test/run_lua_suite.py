"""Run integration scripts; success requires zero exit and a PASS marker.

Usage: python3 test/run_lua_suite.py [--negative-controls] [script.lua ...]
Use --binary or FC_TEST_BINARY to select fc, and --logs for output.
Each invocation has separate logs; each process has isolated settings and fixtures.
"""
from pathlib import Path
import re
import sys
import argparse
import os
import uuid
import tempfile
from lua_runner import run_script

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=Path(os.environ.get('FC_TEST_BINARY', repo / 'build/fc')))
parser.add_argument('--logs', type=Path, default=repo / 'build/review-lua')
parser.add_argument('--negative-only', action='store_true')
parser.add_argument('--negative-controls', action='store_true')
parser.add_argument('scripts', nargs='*')
args = parser.parse_args()
negative = args.negative_controls or args.negative_only
scripts = [repo / arg for arg in args.scripts] if args.scripts else sorted((repo / 'test').glob('test_*.lua')) + [repo / 'test/review_events.lua']
if args.negative_only:
    scripts = []
logs = args.logs / ('run-' + uuid.uuid4().hex[:10])
logs.mkdir(parents=True, exist_ok=True)
print(f'Logs: {logs}', flush=True)


def run(script, name, expect_success=True, expected_error=None):
    with tempfile.TemporaryDirectory(prefix='fc-lua-config-') as config:
        fixtures = Path(config) / 'fixtures'
        fixtures.mkdir()
        rc, seconds, killed, output = run_script(args.binary, script, repo, config, 120, {
            'FC_FRESH_BIN': str(repo / 'test/fakes/fresh_fake.sh'),
            'FC_TEST_TMPDIR': str(fixtures),
            'FC_FRESH_FAKE_LOG': str(Path(config) / 'fresh.log'),
        })
        debug_path = Path(config) / 'lua-debug.log'
        debug = debug_path.read_text() if debug_path.exists() else ''
    (logs / (name + '.log')).write_bytes(output)
    (logs / (name + '.debug.log')).write_text(debug)
    markers = re.findall(rb'\[PASS\] ([^\r\n\x1b]+)', output)
    if expect_success:
        assert not killed and rc == 0 and markers, f'{name}: exit={rc}, timeout={killed}; see {logs / (name + ".log")}'
    else:
        assert not killed and rc > 0, f'{name}: negative control unexpectedly passed or hung (exit={rc})'
        assert expected_error in debug, f'{name}: failed for an unrelated reason; see debug log'
    print(f'PASS {name}: exit={rc}, markers={len(markers)}, {seconds:.2f}s', flush=True)


for script in scripts:
    run(script, script.stem)

if negative:
    controls = [
        ('rebind_disabled', 'test_rebind.lua', 'local raw=fc.key; fc.key=function(k) if k=="cD" then return raw("f9") else return raw(k) end end\n', "copy binding did not change"),
        ('editor_disabled', 'test_editor_integration.lua', 'local raw=fc.key; fc.key=function(k) if k~="f4" then return raw(k) end end\n', "timeout waiting for log entry containing"),
        ('absolute_link_missing', 'test_copy.lua', 'local raw=fc.wait_for_jobs; fc.wait_for_jobs=function(t) local ok=raw(t); os.remove(fc.right_path().."/dangling_link"); return ok end\n', "13: destination dangling link is missing"),
        ('relative_link_missing', 'test_copy.lua', 'local raw=fc.wait_for_jobs; fc.wait_for_jobs=function(t) local ok=raw(t); os.remove(fc.right_path().."/dangling_rel"); return ok end\n', "26: destination dangling link is missing"),
        ('cycle_errors_missing', 'test_copy.lua', 'local raw=fc.errors; fc.errors=function() local out={}; for _,e in ipairs(raw()) do if not e:find("Cyclic symlink",1,true) then table.insert(out,e) end end; return out end\n', "11: cycles must report discovery errors"),
    ]
    with tempfile.TemporaryDirectory(prefix='fc-negative-') as directory:
        for name, source, prefix, expected_error in controls:
            script = Path(directory) / (name + '.lua')
            script.write_text(prefix + (repo / 'test' / source).read_text())
            run(script, name, False, expected_error)
