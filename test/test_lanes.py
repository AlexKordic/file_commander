"""Qualification cannot turn incomplete builds/results or wrong hosts into passes."""
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from test_results import require
repo = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / 'tools'))
from release_gate import required_tests, manual_tests

presets = json.loads((repo / 'CMakePresets.json').read_text())['testPresets']
for preset in presets:
    if preset['name'] == 'manual':
        require(preset['filter']['include']['label'] == 'manual', 'manual preset selection')
    else:
        require('manual' in preset['filter']['exclude']['label'].split('|'), 'automatic preset includes manual checks')

with tempfile.TemporaryDirectory(prefix='fc-lane-check-') as directory:
    root = Path(directory)
    build = root / 'build'
    build.mkdir()
    expected = sorted(required_tests(repo))
    manual = sorted(manual_tests(repo))
    require(set(manual) == {'fc.package', 'fc.fault.exdev', 'fc.regression.watcher_lifetime',
            'fc.regression.late_panel_delivery', 'fc.regression.watcher_recovery',
            'fc.lua.test_archive', 'fc.lua.test_pause_resume'}, 'manual category changed unexpectedly')
    require({'fc.package_build', 'fc.package', 'fc.dependency_rebuild', 'fc.fault.exdev', 'fc.regression.archive_literal_names',
             'fc.fault.move_metadata', 'fc.lua.test_archive', 'fc.command.copy'} <= set(expected), 'release coverage contract')
    (root / 'names.json').write_text(json.dumps(expected))
    (root / 'manual.json').write_text(json.dumps(manual))
    fake = root / 'ctest'
    fake.write_text('#!' + sys.executable + '''
import json, os, sys
from pathlib import Path
mode = os.environ['FC_LANE_CONTROL']
names = json.loads(Path(__file__).with_name('names.json').read_text())
manual = json.loads(Path(__file__).with_name('manual.json').read_text())
if '--show-only=json-v1' in sys.argv:
 if mode == 'one_test': names = ['fixture']
 if mode == 'missing_test': names = names[1:]
 if mode == 'duplicate_test': names.append(names[0])
 if mode == 'missing_manual': names.remove(manual[0])
 tests = [{'name': n, 'command': [sys.executable], 'properties': [{'name': 'LABELS', 'value': ['manual'] if n in manual else []}]} for n in names]
 target = next((t for t in tests if t['name'] in manual), tests[0])
 if mode == 'disabled': target['properties'].append({'name': 'DISABLED', 'value': True})
 if mode == 'unbuilt': target.pop('command')
 if mode == 'wrong_manual_label': target['properties'] = []
 if mode == 'extra_manual_label': next(t for t in tests if t['name'] not in manual)['properties'][0]['value'] = ['manual']
 print(json.dumps({'tests': tests}))
else:
 if '-L' in sys.argv and sys.argv[sys.argv.index('-L')+1] == 'manual':
  names = manual + ([next(n for n in names if n not in manual)] if mode == 'leak_automatic' else [])
 elif '-LE' in sys.argv and 'manual' in sys.argv[sys.argv.index('-LE')+1] and mode != 'leak_manual':
  names = [n for n in names if n not in manual]
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
    for mode in ('missing_manual', 'wrong_manual_label', 'extra_manual_label', 'leak_manual'):
        run(control=mode)
    run('manual', valid=True)
    for mode in ('missing_manual', 'wrong_manual_label', 'extra_manual_label', 'disabled', 'unbuilt',
                 'leak_automatic', 'skip', 'failure', 'error', 'empty', 'missing', 'malformed'):
        run('manual', control=mode)
    metadata_paths = list((build / 'test-logs').glob('lane-release-*/metadata.json'))
    metadata = [json.loads(p.read_text()) for p in metadata_paths]
    successful = next(m for m in metadata if m['status'] == 0)
    require(set(successful['required_tests']) == set(expected) - set(manual), 'automatic release includes manual cases')
    require(set(successful['manual_tests']) == set(manual), 'automatic evidence hides manual requirements')
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
    # Exercise the real package entry point with no compiler toolchain. Replace
    # only native relocation with a sentinel so this check needs no OS services.
    runner = root / 'package runner'
    (runner / 'test').mkdir(parents=True)
    (runner / 'tools').mkdir()
    for relative in ('test/test_package.py', 'tools/release_gate.py'):
        shutil.copy2(repo / relative, runner / relative)
    (runner / 'test/test_packaged_script.py').write_text('''
import os, sys
from pathlib import Path
Path(os.environ['FC_PACKAGE_SMOKE_MARKER']).write_text(sys.argv[1])
raise SystemExit(int(os.environ.get('FC_PACKAGE_SMOKE_STATUS', '0')))
''')
    smoke_marker, build_marker = root / 'smoke-called', root / 'build-called'
    tool_path = root / 'no-toolchain'
    tool_path.mkdir()
    cmake = tool_path / 'cmake'
    cmake.write_text('#!' + sys.executable + '''
import os
from pathlib import Path
Path(os.environ['FC_PACKAGE_BUILD_MARKER']).touch()
raise SystemExit(97)
''')
    cmake.chmod(0o700)
    package_env = dict(os.environ, PATH=str(tool_path),
                       FC_PACKAGE_SMOKE_MARKER=str(smoke_marker), FC_PACKAGE_BUILD_MARKER=str(build_marker))
    package_command = [sys.executable, str(runner / 'test/test_package.py'), str(build), str(archive)]
    def run_package(valid=True, smoke_status=0):
        smoke_marker.unlink(missing_ok=True)
        result = subprocess.run(package_command, env=dict(package_env, FC_PACKAGE_SMOKE_STATUS=str(smoke_status)),
                                capture_output=True, text=True, timeout=5)
        require(not build_marker.exists(), 'manual package test invoked the build toolchain')
        require(smoke_marker.exists() == valid, f'package validation did not guard relocation: {result.stdout} {result.stderr}')
        if valid:
            require(result.returncode == smoke_status, 'relocation result was not propagated')
            require(smoke_marker.read_text() == str(archive), 'relocation used a different archive')
        else:
            require(result.returncode != 0 and 'Package validation failed:' in result.stderr,
                    f'invalid manual package was accepted: {result.stdout} {result.stderr}')
        return result
    run_package()
    run_package(smoke_status=23)
    make_package(stale=True); run_package(valid=False)
    make_package(missing=True); run_package(valid=False)
    archive.write_bytes(b'invalid archive'); run_package(valid=False)
    archive.unlink(); run_package(valid=False); make_package()
    binaries['fresh'].chmod(0o600); run_package(valid=False); binaries['fresh'].chmod(0o700)
    smoke_marker.unlink(missing_ok=True)
    result = subprocess.run([*package_command, '--build-only'], env=package_env,
                            capture_output=True, text=True, timeout=5)
    require(result.returncode != 0 and build_marker.exists() and not smoke_marker.exists(),
            'automatic packaging did not build or ignored the build failure')
    # Reproduce the original bug with a real one-test CTest project.
    (build / 'CTestTestfile.cmake').write_text('add_test(fixture "/usr/bin/true")\n')
    result = run(fake_ctest=False)
    require('incomplete release suite' in result.stderr, 'unrelated real CTest project accepted')
    wrong = 'Linux' if platform.system() == 'Darwin' else 'Darwin'
    result = subprocess.run([*base, 'fast', '--expect-os', wrong], capture_output=True, text=True, timeout=5)
    require(result.returncode != 0 and 'native OS mismatch' in result.stderr, 'cross-host qualification accepted')
print('PASS complete release registry, configuration, results, artifacts, manual package isolation and native host identity')
