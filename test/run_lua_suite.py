"""Run integration scripts; success requires zero exit and a PASS marker.

Usage: python3 test/run_lua_suite.py [--negative-controls] [script.lua ...]
Use --binary or FC_TEST_BINARY to select fc, and --logs for output.
Each invocation has separate logs; each process has isolated settings and fixtures.
"""
from test_results import require, validate_result, validate_protocol
from pathlib import Path
import re
import json
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
parser.add_argument('--case', help='Run one declared copy case')
parser.add_argument('--negative-case', help='Run one negative control')
parser.add_argument('--suite', help='Manifest suite ID for one replacement/negative-control script')
parser.add_argument('scripts', nargs='*')
args = parser.parse_args()
manifest = json.loads((repo / 'test/lua_suites.json').read_text())
require(not args.suite or len(args.scripts) == 1, '--suite requires one script')
negative = args.negative_controls or args.negative_only or bool(args.negative_case)
scripts = [repo / arg for arg in args.scripts] if args.scripts else [repo / entry['script'] for entry in manifest.values()]
if args.negative_only or args.negative_case:
    scripts = []
logs = args.logs / ('run-' + uuid.uuid4().hex[:10])
logs.mkdir(parents=True, exist_ok=True)
print(f'Logs: {logs}', flush=True)


def run(script, name, expect_success=True, expected_error=None, suite=None):
    suite = suite or script.stem
    require(suite in manifest, f"Unknown test suite {suite}; use --suite for replacement scripts or fc run for arbitrary scripts")
    specification = manifest[suite]
    if args.case:
        require(args.case in specification['cases'], f'Unknown case {args.case}')
        specification = dict(specification, cases=[], completion=args.case)
    with tempfile.TemporaryDirectory(prefix='fc-lua-config-') as config:
        fixtures = Path(config) / 'fixtures'
        fixtures.mkdir()
        rc, seconds, killed, output = run_script(args.binary, script, repo, config, 120, {
            'FC_FRESH_BIN': str(repo / 'test/fakes/fresh_fake.sh'),
            'FC_TEST_RESULT_FILE': str(Path(config) / 'results.jsonl'),
            'FC_TEST_SUITE': suite,
            'FC_TEST_PYTHON': sys.executable,
            'FC_TEST_FIXTURE_TOOL': str(repo / 'test/fixture_tool.py'),
            'FC_TEST_COMPLETION': specification['completion'],
            'FC_LUA_CASE': args.case or '',
            'FC_TEST_TMPDIR': str(fixtures),
            'FC_FRESH_FAKE_LOG': str(Path(config) / 'fresh.log'),
        })
        result_path = Path(config) / 'results.jsonl'
        protocol = result_path.read_bytes() if result_path.exists() else b''
        debug_path = Path(config) / 'lua-debug.log'
        debug = debug_path.read_text() if debug_path.exists() else ''
    (logs / (name + '.results.jsonl')).write_bytes(protocol)
    (logs / (name + '.log')).write_bytes(output)
    (logs / (name + '.debug.log')).write_text(debug)
    markers = re.findall(rb'\[PASS\] ([^\r\n\x1b]+)', output)
    validate_result(name, rc, killed, output, debug, expected_error if not expect_success else None)
    if expect_success:
        validate_protocol(suite, specification, protocol)
    print(f'PASS {name}: exit={rc}, markers={len(markers)}, {seconds:.2f}s', flush=True)


for script in scripts:
    run(script, script.stem, suite=args.suite)

if negative:
    controls = json.loads((repo / 'test/negative_controls.json').read_text())
    with tempfile.TemporaryDirectory(prefix='fc-negative-') as directory:
        require(not args.negative_case or args.negative_case in controls, 'Unknown negative control')
        for name, control in controls.items():
            if args.negative_case and name != args.negative_case:
                continue
            source, prefix, expected_error = control['script'], control['prefix'], control['error']
            script = Path(directory) / (name + '.lua')
            script.write_text(prefix + (repo / source).read_text())
            run(script, name, False, expected_error, Path(source).stem)
