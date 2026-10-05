"""Qualification cannot turn incomplete builds/results or wrong hosts into passes."""
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
from test_results import require
repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / 'tools'))
from release_gate import required_tests

with tempfile.TemporaryDirectory(prefix='fc-lane-check-') as directory:
    root = Path(directory)
    build = root / 'build'
    build.mkdir()
    expected = sorted(required_tests(repo))
    require({'fc.package', 'fc.dependency_rebuild', 'fc.fault.exdev', 'fc.regression.archive_literal_names',
             'fc.fault.move_metadata', 'fc.lua.test_archive', 'fc.command.copy'} <= set(expected), 'release coverage contract')
    (root / 'names.json').write_text(json.dumps(expected))
    fake = root / 'ctest'
    fake.write_text('#!' + sys.executable + '''
import json, os, sys
from pathlib import Path
mode = os.environ['FC_LANE_CONTROL']
names = json.loads(Path(__file__).with_name('names.json').read_text())
if '--show-only=json-v1' in sys.argv:
 if mode == 'one_test': names = ['fixture']
 if mode == 'missing_test': names = names[1:]
 if mode == 'duplicate_test': names.append(names[0])
 tests = [{'name': n, 'command': [sys.executable], 'properties': []} for n in names]
 if mode == 'disabled': tests[0]['properties'] = [{'name': 'DISABLED', 'value': True}]
 if mode == 'unbuilt': tests[0].pop('command')
 print(json.dumps({'tests': tests}))
else:
 p = Path(sys.argv[sys.argv.index('--output-junit') + 1])
 if mode == 'one_result': names = ['fixture']
 if mode == 'duplicate_result': names.append(names[0])
 if mode == 'empty': names = []
 payload = {'skip': '<skipped/>', 'failure': '<failure/>', 'error': '<error/>'}.get(mode, '')
 if mode != 'missing':
  p.write_text('<testsuite>' + ''.join('<testcase name="'+n+'">'+payload+'</testcase>' for n in names) + '</testsuite>')
 if mode == 'malformed': p.write_text('not XML')
''')
    fake.chmod(0o700)
    cache = {'CMAKE_HOME_DIRECTORY': str(repo), 'CMAKE_BUILD_TYPE': 'Release', 'BUILD_TESTING': 'ON',
             'FC_CORE_ONLY': 'OFF', 'FC_ALLOW_UNPINNED_DEPENDENCIES': 'OFF', 'FC_BUILD_FRESH': 'ON',
             'FC_BUILD_LZMA_TOOL': 'ON', 'FC_TEST_DEPENDENCY_REBUILDS': 'ON',
             'CMAKE_CACHE_MAJOR_VERSION': '3', 'CMAKE_CACHE_MINOR_VERSION': '30', 'CMAKE_CACHE_PATCH_VERSION': '0'}
    def write_cache(values):
        (build / 'CMakeCache.txt').write_text(''.join(f'{key}:STRING={value}\n' for key, value in values.items()))
    write_cache(cache)
    system = build / 'CMakeFiles/3.30.0/CMakeSystem.cmake'
    system.parent.mkdir(parents=True)
    system.write_text(f'set(CMAKE_SYSTEM_NAME "{platform.system()}")\nset(CMAKE_SYSTEM_PROCESSOR "{platform.machine()}")\nset(CMAKE_CROSSCOMPILING "FALSE")\n')
    binaries = {'fc': build / 'fc', 'fresh': build / 'third_party/fresh/bin/fresh', '7zr': build / 'third_party/lzma/_o/7zr'}
    for path in binaries.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'fixture executable')
        path.chmod(0o700)
    package_name = f'fc-{platform.system()}-{platform.machine()}'
    archive = build / 'dist' / (package_name + '.tar.gz')
    archive.parent.mkdir()
    def make_package(stale=False, missing=False):
        with tarfile.open(archive, 'w:gz') as package:
            for name, path in binaries.items():
                if missing and name == '7zr': continue
                data = b'old executable' if stale else path.read_bytes()
                member = tarfile.TarInfo(f'{package_name}/bin/{name}')
                member.size = len(data); member.mode = 0o755
                package.addfile(member, io.BytesIO(data))
    make_package()
    base = [sys.executable, str(repo / 'tools/run_test_lane.py')]
    def run(lane='release', control='pass', valid=False, fake_ctest=True):
        env = dict(os.environ, FC_LANE_CONTROL=control)
        if fake_ctest: env['PATH'] = str(root) + os.pathsep + env['PATH']
        result = subprocess.run([*base, lane, '--build', str(build)], env=env, capture_output=True, text=True, timeout=5)
        require((result.returncode == 0) == valid, f'lane control {lane}/{control}: {result.stdout} {result.stderr}')
        return result
    run(valid=True)
    for mode in ('one_test', 'missing_test', 'duplicate_test', 'disabled', 'unbuilt', 'one_result',
                 'duplicate_result', 'skip', 'failure', 'error', 'empty', 'missing', 'malformed'):
        run(control=mode)
    run('fast', valid=True)
    run('fast', 'skip', valid=True)
    for mode in ('empty', 'missing', 'failure', 'malformed'): run('fast', mode)
    for key, value in [('CMAKE_HOME_DIRECTORY', str(root)), ('CMAKE_BUILD_TYPE', 'Debug'), ('BUILD_TESTING', 'OFF'),
                       ('FC_CORE_ONLY', 'ON'), ('FC_ALLOW_UNPINNED_DEPENDENCIES', 'ON'), ('FC_BUILD_FRESH', 'OFF'),
                       ('FC_BUILD_LZMA_TOOL', 'OFF'), ('FC_TEST_DEPENDENCY_REBUILDS', 'OFF'), ('FETCHCONTENT_SOURCE_DIR_BOOST', '/unchecked')]:
        write_cache(dict(cache, **{key: value})); run()
    write_cache(cache)
    native = system.read_text()
    system.write_text(native.replace('"FALSE"', '"TRUE"')); run(); system.write_text(native)
    for path in binaries.values():
        path.chmod(0o600); run(); path.chmod(0o700)
    make_package(stale=True); run()
    make_package(missing=True); run()
    archive.unlink(); run(); make_package()
    # Reproduce the original bug with a real one-test CTest project.
    (build / 'CTestTestfile.cmake').write_text('add_test(fixture "/usr/bin/true")\n')
    result = run(fake_ctest=False)
    require('incomplete release suite' in result.stderr, 'unrelated real CTest project accepted')
    wrong = 'Linux' if platform.system() == 'Darwin' else 'Darwin'
    result = subprocess.run([*base, 'fast', '--expect-os', wrong], capture_output=True, text=True, timeout=5)
    require(result.returncode != 0 and 'native OS mismatch' in result.stderr, 'cross-host qualification accepted')
print('PASS complete release registry, configuration, results, artifacts and native host identity')
