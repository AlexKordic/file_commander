"""Protocol rejects incomplete, duplicate, unknown and forged completions."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from test_results import TestFailure, require, validate_protocol

spec = {'cases': ['first', 'second'], 'completion': 'done'}
records = [{'kind': kind, 'suite': 'fixture', 'id': name, 'status': 'passed'}
           for kind, name in [('case', 'first'), ('case', 'second'), ('complete', 'done')]]


def encode(items):
    return ''.join(json.dumps(item) + '\n' for item in items).encode()


validate_protocol('fixture', spec, encode(records))
invalid = [b'', encode(records[:1]), encode(records[:-1]), encode(records + records[-1:]),
           encode(records[::-1]), b'{truncated', encode(records).replace(b'fixture', b'wrong'),
           encode(records).replace(b'second', b'unknown')]
for data in invalid:
    try:
        validate_protocol('fixture', spec, data)
    except TestFailure:
        pass
    else:
        raise TestFailure(f'accepted invalid protocol: {data}')
repo = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / 'build/fc'
with tempfile.TemporaryDirectory(prefix='fc-protocol-') as temp:
    root = Path(temp)
    source = (repo / 'test/test_copy.lua').read_text()
    script = root / 'partial.lua'
    script.write_text(source[:source.index('-- 2. Basic copy: multiple files')] + '\ntest_basic_single_file()\n')
    for flags in ([], ['-O']):
        result = subprocess.run([sys.executable, *flags, str(repo / 'test/run_lua_suite.py'),
                                 '--binary', str(binary), '--logs', str(root / 'logs'),
                                 '--suite', 'test_copy', str(script)], capture_output=True, text=True, timeout=15)
        require(result.returncode != 0 and 'incomplete or duplicate' in result.stderr,
                'partial suite passed or failed for unrelated reason: ' + result.stdout + result.stderr)
print('PASS strict suite result protocol and premature-return controls')
