"""Exercise runner decisions in normal and optimized interpreters."""
import os
from pathlib import Path
import subprocess
import sys
from test_results import TestFailure, require, validate_result


def checks():
    invalid = [
        ((0, False, b''), {}, 'marker missing'),
        ((2, False, b'[PASS] fake'), {}, 'exit 2'),
        ((-15, False, b'[PASS] fake'), {}, 'signal 15'),
        ((0, True, b'[PASS] fake'), {}, 'timeout'),
        ((0, False, b'[PASS] fake'), {'expected_error': 'expected'}, 'unexpectedly passed'),
        ((1, False, b''), {'debug': 'wrong', 'expected_error': 'expected'}, 'unrelated reason'),
    ]
    for values, options, message in invalid:
        try:
            validate_result('fixture', *values, **options)
        except TestFailure as error:
            require(message in str(error), f'incorrect failure category: {error}')
        else:
            raise TestFailure(f'accepted invalid result: {values}')
    validate_result('positive', 0, False, b'[PASS] fixture')
    validate_result('negative', 1, False, b'', 'expected error', 'expected')


if __name__ == '__main__':
    if '--child' in sys.argv:
        checks()
        print('PASS result checks')
    else:
        env = os.environ.copy()
        env.pop('PYTHONOPTIMIZE', None)
        for flags, child_env in [([], env), (['-O'], env), ([], dict(env, PYTHONOPTIMIZE='1'))]:
            result = subprocess.run([sys.executable, *flags, str(Path(__file__).resolve()), '--child'],
                                    env=child_env, capture_output=True, text=True, timeout=10)
            require(result.returncode == 0 and 'PASS result checks' in result.stdout, result.stdout + result.stderr)
            command = [sys.executable, *flags, str(Path(__file__).with_name('run_lua_suite.py')),
                       '--binary', '/usr/bin/true', 'test/test_find.lua']
            rejected = subprocess.run(command, env=child_env, capture_output=True, text=True, timeout=10)
            require(rejected.returncode != 0 and 'completion marker missing' in rejected.stderr,
                    'empty binary passed through the CLI: ' + rejected.stdout + rejected.stderr)
        print('PASS result validation: normal, -O, PYTHONOPTIMIZE=1')
